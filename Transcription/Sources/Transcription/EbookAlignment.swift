import Foundation

/// Why alignment can refuse to produce output. Refusal matters as much as success: replacing a
/// working ASR transcript with text from the *wrong edition* (abridged audio, revised text,
/// translation) would be strictly worse than leaving the ASR alone, so the caller is expected to
/// treat these as "keep what you have", not as failures to retry.
public enum EbookAlignmentError: Error, Equatable {
  case emptyBook
  case emptyTranscript
  /// Too few unique phrases in common to trust any mapping — different books, most likely.
  case insufficientAnchors(found: Int)
  /// Anchoring worked but too little of the audio's text matches the book's. Abridgement or
  /// heavy edition drift; carries the measured fraction for the log line.
  case lowMatch(fraction: Double)
}

/// Aligns an ebook's text to an ASR transcript so the book's own prose becomes the transcript.
///
/// The ASR side supplies *when* things are said; the epub supplies *what* — real punctuation, real
/// paragraphing, and proper nouns spelled the way the author spelled them, which no speech model
/// on this library manages ("Hermy-own-ninny" is in this corpus). The output is the book's
/// sentences carrying ASR-derived timings, ready for `TranscriptChunker.bucket` like any other
/// producer's segments.
///
/// Method: tokenize both streams to normalized words → anchor on 4-grams that occur exactly once
/// in each (longest-increasing-subsequence keeps the chain monotonic, so a phrase the narrator
/// repeats can't cross-wire two chapters) → close the gaps between anchors with bounded
/// Needleman–Wunsch where they're small enough to trust, linear interpolation where they aren't →
/// emit the book's sentences with times read off the mapped tokens. Book text outside the
/// narrated span (front matter, appendices) is dropped rather than given invented timestamps.
public enum EbookAlignment {
  public struct Result: Sendable {
    public let segments: [TranscriptSegment]
    /// Exactly-matched ASR tokens over all ASR tokens inside the anchored span — the honesty
    /// number the quality gate reads.
    public let matchedFraction: Double
    public let anchorCount: Int
  }

  /// Tunables with the shipped defaults. A struct rather than free parameters so tests can turn
  /// one knob without restating the rest.
  public struct Options: Sendable {
    /// Refuse below this `matchedFraction`.
    public var minimumMatch: Double = 0.5
    /// Gap regions up to this many tokens (each side) get real token alignment; larger ones only
    /// interpolate. Bounds worst-case work to gapLimit² per gap.
    public var gapLimit: Int = 600
    /// Sentences longer than this split at the last clause break before the cap.
    public var maxSentenceTokens: Int = 48

    public init() {}
  }

  public static func align(
    bookText: String,
    asr: [TranscriptSegment],
    options: Options = Options()
  ) throws -> Result {
    let sentences = BookTokenizer.sentences(in: bookText, maxTokens: options.maxSentenceTokens)
    let bookTokens = sentences.flatMap(\.tokens)
    guard !bookTokens.isEmpty else { throw EbookAlignmentError.emptyBook }

    let asrTokens = AsrTokenizer.tokens(from: asr)
    guard !asrTokens.isEmpty else { throw EbookAlignmentError.emptyTranscript }

    // --- Anchors ---
    var anchors = Self.anchors(
      book: bookTokens.map(\.norm),
      asr: asrTokens.map(\.norm),
      n: 4
    )
    if anchors.count < 8 {
      let coarse = Self.anchors(book: bookTokens.map(\.norm), asr: asrTokens.map(\.norm), n: 3)
      if coarse.count > anchors.count { anchors = coarse }
    }
    guard anchors.count >= 4 else {
      throw EbookAlignmentError.insufficientAnchors(found: anchors.count)
    }

    // --- Exact pairs: anchor n-grams, then NW inside bounded gaps ---
    var pairs: [(book: Int, asr: Int)] = []
    var lastBook = -1
    var lastAsr = -1
    for anchor in anchors {
      for offset in 0..<anchor.length {
        let b = anchor.book + offset
        let a = anchor.asr + offset
        if b > lastBook, a > lastAsr {
          pairs.append((b, a))
          lastBook = b
          lastAsr = a
        }
      }
    }

    var filled: [(book: Int, asr: Int)] = []
    filled.reserveCapacity(pairs.count * 2)
    for (index, pair) in pairs.enumerated() {
      if index > 0 {
        let previous = pairs[index - 1]
        let bookGap = (previous.book + 1)..<pair.book
        let asrGap = (previous.asr + 1)..<pair.asr
        if !bookGap.isEmpty, !asrGap.isEmpty,
          bookGap.count <= options.gapLimit, asrGap.count <= options.gapLimit
        {
          let matches = NeedlemanWunsch.matches(
            left: bookGap.map { bookTokens[$0].norm },
            right: asrGap.map { asrTokens[$0].norm }
          )
          for match in matches {
            filled.append((bookGap.lowerBound + match.left, asrGap.lowerBound + match.right))
          }
        }
      }
      filled.append(pair)
    }
    pairs = filled

    guard let firstPair = pairs.first, let lastPair = pairs.last else {
      throw EbookAlignmentError.insufficientAnchors(found: 0)
    }
    let asrSpanCount = lastPair.asr - firstPair.asr + 1
    let matchedFraction = Double(pairs.count) / Double(max(1, asrSpanCount))
    guard matchedFraction >= options.minimumMatch else {
      throw EbookAlignmentError.lowMatch(fraction: matchedFraction)
    }

    // --- Times for every book token in the narrated span ---
    let timeline = TokenTimeline(pairs: pairs, asrTokens: asrTokens)

    // --- Emit book sentences ---
    var out: [TranscriptSegment] = []
    out.reserveCapacity(sentences.count)
    var usedSegIDs = Set<Int>()
    var previousStart = -Double.greatestFiniteMagnitude

    for sentence in sentences {
      guard !sentence.tokens.isEmpty else { continue }
      let range = sentence.globalRange
      // Entirely outside the narrated span → not read aloud → no segment.
      guard range.upperBound > firstPair.book, range.lowerBound <= lastPair.book else { continue }

      let mapped = range.clamped(to: firstPair.book..<(lastPair.book + 1))
      guard !mapped.isEmpty else { continue }

      let times = mapped.map { timeline.time(forBookToken: $0) }
      var start = times.first!.start
      var end = times.last!.end
      start = max(start, previousStart)  // monotonic starts keep the player's binary search sane
      end = max(end, start + 0.2)
      previousStart = start

      var seg = Int((start * 1000).rounded())
      while !usedSegIDs.insert(seg).inserted { seg += 1 }

      let exactCount = mapped.filter { timeline.isExact(bookToken: $0) }.count
      let words: [TranscriptWord]? =
        Double(exactCount) >= 0.7 * Double(mapped.count) && mapped.count == range.count
        ? Self.words(for: sentence, times: times, floor: start)
        : nil

      out.append(
        TranscriptSegment(
          seg: seg,
          track: times.first!.track,
          start: start,
          end: end,
          text: sentence.text,
          words: words
        )
      )
    }

    return Result(
      segments: out,
      matchedFraction: matchedFraction,
      anchorCount: anchors.count
    )
  }

  /// Word entries whose concatenated `text` reproduces the sentence verbatim (the karaoke
  /// contract): each token's piece carries the punctuation and spacing that preceded it, and the
  /// final piece carries the sentence's tail.
  private static func words(
    for sentence: BookTokenizer.Sentence,
    times: [TokenTimeline.TokenTime],
    floor: Double
  ) -> [TranscriptWord] {
    var words: [TranscriptWord] = []
    words.reserveCapacity(sentence.tokens.count)
    var clock = floor
    for (index, token) in sentence.tokens.enumerated() {
      let start = max(times[index].start, clock)
      let end = max(times[index].end, start)
      clock = start
      words.append(TranscriptWord(text: token.piece, start: start, end: end))
    }
    return words
  }

  // MARK: - Anchoring

  struct Anchor {
    let book: Int
    let asr: Int
    let length: Int
  }

  /// N-grams occurring exactly once in each stream, chained monotonic via longest increasing
  /// subsequence on the book index (candidates pre-sorted by ASR index).
  static func anchors(book: [String], asr: [String], n: Int) -> [Anchor] {
    guard book.count >= n, asr.count >= n else { return [] }

    func uniqueGrams(_ tokens: [String]) -> [String: Int] {
      var positions: [String: Int] = [:]
      var dead = Set<String>()
      for index in 0...(tokens.count - n) {
        let gram = tokens[index..<(index + n)].joined(separator: "\u{1}")
        if dead.contains(gram) { continue }
        if positions[gram] != nil {
          positions.removeValue(forKey: gram)
          dead.insert(gram)
        } else {
          positions[gram] = index
        }
      }
      return positions
    }

    let bookGrams = uniqueGrams(book)
    let asrGrams = uniqueGrams(asr)

    var candidates: [(asr: Int, book: Int)] = []
    for (gram, asrIndex) in asrGrams {
      if let bookIndex = bookGrams[gram] {
        candidates.append((asrIndex, bookIndex))
      }
    }
    candidates.sort { $0.asr < $1.asr }

    // LIS (strictly increasing book indices) with predecessor links.
    var tailIndexes: [Int] = []  // candidate index with smallest tail book value per length
    var predecessors = [Int](repeating: -1, count: candidates.count)
    for (index, candidate) in candidates.enumerated() {
      var low = 0
      var high = tailIndexes.count
      while low < high {
        let mid = (low + high) / 2
        if candidates[tailIndexes[mid]].book < candidate.book { low = mid + 1 } else { high = mid }
      }
      if low > 0 { predecessors[index] = tailIndexes[low - 1] }
      if low == tailIndexes.count { tailIndexes.append(index) } else { tailIndexes[low] = index }
    }

    var chain: [Anchor] = []
    var cursor = tailIndexes.last ?? -1
    while cursor >= 0 {
      let candidate = candidates[cursor]
      chain.append(Anchor(book: candidate.book, asr: candidate.asr, length: n))
      cursor = predecessors[cursor]
    }
    return chain.reversed()
  }
}

// MARK: - Token timeline

/// Time lookup for book tokens: exact where a pair exists, linear interpolation between the
/// nearest pairs otherwise.
private struct TokenTimeline {
  struct TokenTime {
    let start: TimeInterval
    let end: TimeInterval
    let track: Int
  }

  private let pairedBookIndexes: [Int]
  private let pairedTimes: [TokenTime]
  private let exact: Set<Int>

  init(pairs: [(book: Int, asr: Int)], asrTokens: [AsrTokenizer.Token]) {
    pairedBookIndexes = pairs.map(\.book)
    pairedTimes = pairs.map { pair in
      let token = asrTokens[pair.asr]
      return TokenTime(start: token.start, end: token.end, track: token.track)
    }
    exact = Set(pairedBookIndexes)
  }

  func isExact(bookToken index: Int) -> Bool {
    exact.contains(index)
  }

  func time(forBookToken index: Int) -> TokenTime {
    var low = 0
    var high = pairedBookIndexes.count - 1
    var found = -1
    while low <= high {
      let mid = (low + high) / 2
      if pairedBookIndexes[mid] <= index {
        found = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }

    if found >= 0, pairedBookIndexes[found] == index { return pairedTimes[found] }
    if found < 0 { return pairedTimes[0] }
    if found == pairedBookIndexes.count - 1 { return pairedTimes[found] }

    let before = pairedTimes[found]
    let after = pairedTimes[found + 1]
    let gapTokens = Double(pairedBookIndexes[found + 1] - pairedBookIndexes[found])
    let fraction = Double(index - pairedBookIndexes[found]) / max(gapTokens, 1)
    let instant = before.end + (after.start - before.end) * fraction
    return TokenTime(start: instant, end: instant, track: before.track)
  }
}

// MARK: - Tokenizers

enum BookTokenizer {
  struct Token {
    let norm: String
    /// Original text from the end of the previous token (or sentence start) through this token's
    /// end — concatenating pieces reproduces the sentence verbatim.
    let piece: String
  }

  struct Sentence {
    let text: String
    let tokens: [Token]
    /// Indices into the whole book's token stream.
    let globalRange: Range<Int>
  }

  /// Sentence enders. A newline is always a hard break — epub block elements became newlines in
  /// `EbookHTML`, and a heading like "CHAPTER 3" has no terminal punctuation.
  private static let enders: Set<Character> = [".", "!", "?", "…"]
  private static let closers: Set<Character> = ["\"", "'", "\u{2019}", "\u{201D}", ")", "]"]

  static func sentences(in text: String, maxTokens: Int) -> [Sentence] {
    var rawSentences: [String] = []
    var current = ""

    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "\n" {
        rawSentences.append(current)
        current = ""
        index = text.index(after: index)
        continue
      }
      current.append(character)
      if enders.contains(character) {
        // Attach closing quotes/brackets, then break if what follows is whitespace.
        var probe = text.index(after: index)
        while probe < text.endIndex, closers.contains(text[probe]) {
          current.append(text[probe])
          probe = text.index(after: probe)
        }
        if probe >= text.endIndex || text[probe] == " " || text[probe] == "\n" {
          rawSentences.append(current)
          current = ""
          // Consume the single following space, if any.
          if probe < text.endIndex, text[probe] == " " { probe = text.index(after: probe) }
        }
        index = probe
        continue
      }
      index = text.index(after: index)
    }
    rawSentences.append(current)

    var sentences: [Sentence] = []
    var globalIndex = 0
    for raw in rawSentences {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      for piece in split(trimmed, maxTokens: maxTokens) {
        let tokens = tokenize(piece)
        guard !tokens.isEmpty else { continue }
        sentences.append(
          Sentence(
            text: piece,
            tokens: tokens,
            globalRange: globalIndex..<(globalIndex + tokens.count)
          )
        )
        globalIndex += tokens.count
      }
    }
    return sentences
  }

  /// Split an over-long sentence at the last clause break (comma family) before the cap; hard
  /// split when a clause itself exceeds the cap. Keeps karaoke lines readable and the active-line
  /// resolution near the ASR's own granularity.
  private static func split(_ sentence: String, maxTokens: Int) -> [String] {
    let tokens = tokenize(sentence)
    guard tokens.count > maxTokens else { return [sentence] }

    let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–"]
    var pieces: [String] = []
    var pieceStart = sentence.startIndex
    var tokenCount = 0
    var lastBreak: String.Index? = nil

    var index = sentence.startIndex
    var inToken = false
    while index < sentence.endIndex {
      let character = sentence[index]
      let isTokenChar = character.isLetter || character.isNumber
      if isTokenChar, !inToken {
        inToken = true
        tokenCount += 1
      } else if !isTokenChar {
        inToken = false
        if clauseBreaks.contains(character) { lastBreak = sentence.index(after: index) }
      }

      if tokenCount > maxTokens {
        let cut = lastBreak ?? index
        let piece = String(sentence[pieceStart..<cut]).trimmingCharacters(in: .whitespaces)
        if !piece.isEmpty { pieces.append(piece) }
        pieceStart = cut
        tokenCount = 0
        lastBreak = nil
        inToken = false
        index = cut
        continue
      }
      index = sentence.index(after: index)
    }
    let tail = String(sentence[pieceStart...]).trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty { pieces.append(tail) }
    return pieces
  }

  static func tokenize(_ sentence: String) -> [Token] {
    var tokens: [Token] = []
    var pieceStart = sentence.startIndex
    var index = sentence.startIndex

    while index < sentence.endIndex {
      if sentence[index].isLetter || sentence[index].isNumber {
        let tokenStart = index
        while index < sentence.endIndex,
          sentence[index].isLetter || sentence[index].isNumber
            || sentence[index] == "'" || sentence[index] == "\u{2019}"
        {
          index = sentence.index(after: index)
        }
        let norm = normalize(sentence[tokenStart..<index])
        if !norm.isEmpty {
          tokens.append(Token(norm: norm, piece: String(sentence[pieceStart..<index])))
          pieceStart = index
        }
      } else {
        index = sentence.index(after: index)
      }
    }

    // The tail (closing punctuation after the last word) belongs to the last word's piece so
    // concatenation stays verbatim.
    if var last = tokens.popLast() {
      last = Token(norm: last.norm, piece: last.piece + String(sentence[pieceStart...]))
      tokens.append(last)
    }
    return tokens
  }

  static func normalize<S: StringProtocol>(_ word: S) -> String {
    var out = ""
    out.reserveCapacity(word.count)
    for character in word.lowercased() where character.isLetter || character.isNumber {
      out.append(character)
    }
    return out
  }
}

enum AsrTokenizer {
  struct Token {
    let norm: String
    let start: TimeInterval
    let end: TimeInterval
    let track: Int
  }

  static func tokens(from segments: [TranscriptSegment]) -> [Token] {
    var out: [Token] = []
    for segment in segments.sorted(by: { $0.start < $1.start }) {
      if let words = segment.words, !words.isEmpty {
        for word in words {
          for norm in norms(of: word.text) {
            out.append(Token(norm: norm, start: word.start, end: word.end, track: segment.track))
          }
        }
      } else {
        let norms = norms(of: segment.text)
        guard !norms.isEmpty else { continue }
        let step = (segment.end - segment.start) / Double(norms.count)
        for (index, norm) in norms.enumerated() {
          let start = segment.start + step * Double(index)
          out.append(
            Token(norm: norm, start: start, end: start + step, track: segment.track)
          )
        }
      }
    }
    return out
  }

  private static func norms(of text: String) -> [String] {
    text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "\u{2019}" })
      .map { BookTokenizer.normalize($0) }
      .filter { !$0.isEmpty }
  }
}

// MARK: - Bounded gap alignment

/// Token-level Needleman–Wunsch, used only inside anchor gaps small enough that quadratic work is
/// trivial. Returns the equal-token matches on the optimal path (mismatched substitutions are not
/// matches — a paired "hermione"/"hermyownninny" would poison the timeline with a wrong time).
enum NeedlemanWunsch {
  struct Match {
    let left: Int
    let right: Int
  }

  static func matches(left: [String], right: [String]) -> [Match] {
    let n = left.count
    let m = right.count
    guard n > 0, m > 0 else { return [] }

    let matchScore = 2
    let mismatch = -1
    let gap = -1

    var score = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 1...n { score[i][0] = score[i - 1][0] + gap }
    for j in 1...m { score[0][j] = score[0][j - 1] + gap }
    for i in 1...n {
      for j in 1...m {
        let diagonal = score[i - 1][j - 1] + (left[i - 1] == right[j - 1] ? matchScore : mismatch)
        score[i][j] = max(diagonal, max(score[i - 1][j] + gap, score[i][j - 1] + gap))
      }
    }

    var matches: [Match] = []
    var i = n
    var j = m
    while i > 0, j > 0 {
      let cell = score[i][j]
      let equal = left[i - 1] == right[j - 1]
      if cell == score[i - 1][j - 1] + (equal ? matchScore : mismatch) {
        if equal { matches.append(Match(left: i - 1, right: j - 1)) }
        i -= 1
        j -= 1
      } else if cell == score[i - 1][j] + gap {
        i -= 1
      } else {
        j -= 1
      }
    }
    return matches.reversed()
  }
}
