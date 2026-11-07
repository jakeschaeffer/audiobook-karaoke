import Foundation
import Testing

@testable import Transcription

@Suite("Ebook ↔ ASR alignment")
struct EbookAlignmentTests {
  // MARK: - Deterministic fixture generation

  /// Tiny LCG so fixtures are stable across runs and platforms — no seeded RNG in Foundation.
  private struct LCG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(state >> 33) % bound
    }
  }

  private static let vocabulary: [String] = [
    "green", "light", "outlaw", "logic", "highway", "father", "mother", "texas", "diesel",
    "morning", "river", "trumpet", "bumper", "sticker", "wet", "dream", "catching", "story",
    "living", "poetry", "prescription", "approval", "denial", "ritual", "crossing", "desert",
    "monastery", "wrestle", "dirt", "road", "family", "brother", "engine", "silver", "dollar",
    "kitchen", "ladder", "midnight", "cowboy", "guitar", "border", "canyon", "flood", "sermon",
    "victory", "lap", "compass", "arrow", "target", "season", "harvest", "ranch", "cattle",
    "fence", "storm", "shelter", "market", "corner", "letter", "journal", "notebook", "margin",
  ]

  /// `count` sentences of pseudo-prose, 8–15 words each, every 12th its own paragraph.
  private static func makeSentences(count: Int, seed: UInt64) -> [[String]] {
    var rng = LCG(state: seed)
    return (0..<count).map { _ in
      let length = 8 + rng.next(8)
      var previous = -1
      return (0..<length).map { _ -> String in
        var pick = rng.next(vocabulary.count)
        if pick == previous { pick = (pick + 7) % vocabulary.count }  // avoid immediate repeats
        previous = pick
        return vocabulary[pick]
      }
    }
  }

  private static func bookText(from sentences: [[String]]) -> String {
    sentences.enumerated().map { index, words in
      var sentence = words.joined(separator: " ")
      sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
      sentence += index % 5 == 3 ? "!" : "."
      return index % 12 == 11 ? sentence + "\n" : sentence
    }.joined(separator: " ")
  }

  /// ASR truth: word i (over the flattened token stream) speaks at `i * 0.4`, lasting 0.35s.
  /// Segments break every 10 words. `mutate` can replace (substitution) or drop (deletion) a
  /// token, or inject one after it (insertion), keyed by flat index.
  private static func makeASR(
    from sentences: [[String]],
    mutate: (Int, String) -> [String]? = { _, word in [word] }
  ) -> [TranscriptSegment] {
    var spoken: [String] = []
    for sentence in sentences {
      for (index, word) in zip(spoken.count..., sentence) {
        spoken.append(contentsOf: mutate(index, word) ?? [])
      }
    }

    var segments: [TranscriptSegment] = []
    var cursor = 0
    while cursor < spoken.count {
      let slice = Array(spoken[cursor..<min(cursor + 10, spoken.count)])
      let start = Double(cursor) * 0.4
      let words = slice.enumerated().map { offset, word in
        TranscriptWord(
          text: (offset == 0 ? "" : " ") + word,
          start: Double(cursor + offset) * 0.4,
          end: Double(cursor + offset) * 0.4 + 0.35
        )
      }
      segments.append(
        TranscriptSegment(
          seg: cursor,
          track: 1,
          start: start,
          end: words.last!.end,
          text: slice.joined(separator: " "),
          words: words
        )
      )
      cursor += slice.count
    }
    return segments
  }

  // MARK: - Tests

  @Test("clean ASR: book sentences come back verbatim with truth-accurate times")
  func cleanAlignment() throws {
    let sentences = Self.makeSentences(count: 80, seed: 42)
    let book = Self.bookText(from: sentences)
    let asr = Self.makeASR(from: sentences)

    let result = try EbookAlignment.align(bookText: book, asr: asr)

    #expect(result.matchedFraction > 0.95)
    // Every output sentence is book text (capitalized, punctuated) — not ASR text.
    let joinedOut = result.segments.map(\.text).joined(separator: " ")
    let joinedBook = book.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "  ", with: " ")
    #expect(joinedOut == joinedBook.trimmingCharacters(in: .whitespaces))

    // Times track the truth: sentence k starts when its first word is spoken.
    var flatIndex = 0
    for (sentence, segment) in zip(sentences, result.segments) {
      let truth = Double(flatIndex) * 0.4
      #expect(abs(segment.start - truth) < 0.75, "sentence start drifted from truth")
      flatIndex += sentence.count
    }

    // Monotonic starts, positive spans.
    for (previous, next) in zip(result.segments, result.segments.dropFirst()) {
      #expect(next.start >= previous.start)
      #expect(next.end >= next.start)
    }
  }

  @Test("word timings: pieces concatenate to the sentence verbatim")
  func wordPieces() throws {
    let sentences = Self.makeSentences(count: 30, seed: 7)
    let result = try EbookAlignment.align(
      bookText: Self.bookText(from: sentences),
      asr: Self.makeASR(from: sentences)
    )
    let withWords = result.segments.filter(\.hasWordTimings)
    #expect(withWords.count > result.segments.count / 2)
    for segment in withWords {
      let rebuilt = (segment.words ?? []).map(\.text).joined()
      #expect(rebuilt == segment.text)
      for (a, b) in zip(segment.words ?? [], (segment.words ?? []).dropFirst()) {
        #expect(b.start >= a.start)
      }
    }
  }

  @Test("10% substitutions + insertions: text still comes from the book, times hold")
  func noisyAlignment() throws {
    let sentences = Self.makeSentences(count: 100, seed: 99)
    let book = Self.bookText(from: sentences)
    let asr = Self.makeASR(from: sentences) { index, word in
      if index % 10 == 3 { return ["blurble\(index)"] }  // misrecognition
      if index % 37 == 5 { return [word, "um"] }  // disfluency insertion
      if index % 53 == 7 { return [] }  // dropped word
      return [word]
    }

    let result = try EbookAlignment.align(bookText: book, asr: asr)

    #expect(result.matchedFraction > 0.6)
    // The output must contain the *original* words where ASR misheard.
    let allText = result.segments.map(\.text).joined(separator: " ")
    #expect(!allText.contains("blurble"))
    #expect(!allText.contains(" um"))
    // Sentence count survives (no wholesale drops mid-book).
    #expect(result.segments.count == sentences.count)
    for (previous, next) in zip(result.segments, result.segments.dropFirst()) {
      #expect(next.start >= previous.start)
    }
  }

  @Test("front matter without audio is dropped; narrated body isn't")
  func frontMatterDropped() throws {
    let sentences = Self.makeSentences(count: 60, seed: 5)
    let frontMatter = "Copyright 2020 by Crown Publishing. All rights reserved. ISBN 9780593139134.\n\n"
    let book = frontMatter + Self.bookText(from: sentences)
    let asr = Self.makeASR(from: sentences)

    let result = try EbookAlignment.align(bookText: book, asr: asr)

    let allText = result.segments.map(\.text).joined(separator: " ")
    #expect(!allText.contains("ISBN"))
    #expect(result.segments.count >= sentences.count - 1)
    if let first = result.segments.first {
      #expect(first.start < 1.0)  // body starts at the top of the audio
    }
  }

  @Test("publisher intro in audio but not in book: no book sentence gets its time span")
  func audioOnlyIntroTolerated() throws {
    let sentences = Self.makeSentences(count: 60, seed: 13)
    let intro: [[String]] = [["this", "is", "audible"], ["narrated", "by", "the", "author"]]
    let asr = Self.makeASR(from: intro + sentences)
    let book = Self.bookText(from: sentences)

    let result = try EbookAlignment.align(bookText: book, asr: asr)

    // First book sentence begins where the body begins (7 intro tokens * 0.4s = 2.8s), not at 0.
    if let first = result.segments.first {
      #expect(abs(first.start - 2.8) < 1.0)
    }
    #expect(result.segments.count == sentences.count)
  }

  @Test("unrelated texts refuse to align")
  func refusesUnrelated() {
    let bookSentences = Self.makeSentences(count: 40, seed: 1)
    let otherSentences = Self.makeSentences(count: 40, seed: 2_000_000)
    #expect(throws: EbookAlignmentError.self) {
      try EbookAlignment.align(
        bookText: Self.bookText(from: bookSentences),
        asr: Self.makeASR(from: otherSentences)
      )
    }
  }

  @Test("empty inputs throw the right errors")
  func emptyInputs() {
    let sentences = Self.makeSentences(count: 5, seed: 3)
    #expect(throws: EbookAlignmentError.emptyBook) {
      try EbookAlignment.align(bookText: " \n ", asr: Self.makeASR(from: sentences))
    }
    #expect(throws: EbookAlignmentError.emptyTranscript) {
      try EbookAlignment.align(bookText: Self.bookText(from: sentences), asr: [])
    }
  }

  @Test("sentence splitter: hard caps split at clause breaks; headings stand alone")
  func sentenceSplitting() {
    let words = (0..<70).map { "word\($0)" }
    let long =
      words[0..<30].joined(separator: " ") + ", " + words[30..<70].joined(separator: " ") + "."
    let text = "CHAPTER ONE\n" + long
    let sentences = BookTokenizer.sentences(in: text, maxTokens: 48)

    #expect(sentences.count == 3)
    #expect(sentences[0].text == "CHAPTER ONE")
    #expect(sentences[1].tokens.count == 30)  // split at the comma, not mid-clause
    #expect(sentences[2].tokens.count == 40)
    // Global token ranges tile without gaps.
    #expect(sentences[0].globalRange == 0..<2)
    #expect(sentences[1].globalRange.lowerBound == 2)
    #expect(
      sentences[2].globalRange.upperBound
        == sentences.reduce(0) { $0 + $1.tokens.count }
    )
  }

  @Test("Needleman–Wunsch returns only equal-token matches, in order")
  func needlemanWunsch() {
    let matches = NeedlemanWunsch.matches(
      left: ["a", "b", "c", "d", "e"],
      right: ["a", "x", "c", "e"]
    )
    #expect(matches.map { [$0.left, $0.right] } == [[0, 0], [2, 2], [4, 3]])
  }

  @Test("repeated phrases can't cross-wire chapters (monotonic anchors)")
  func repetitionStaysMonotonic() throws {
    // The same distinctive sentence appears in chapter 1 and chapter 30.
    var sentences = Self.makeSentences(count: 60, seed: 21)
    let refrain = ["catching", "greenlights", "is", "about", "skill", "and", "timing"]
    sentences[2] = refrain
    sentences[45] = refrain
    let result = try EbookAlignment.align(
      bookText: Self.bookText(from: sentences),
      asr: Self.makeASR(from: sentences)
    )
    for (previous, next) in zip(result.segments, result.segments.dropFirst()) {
      #expect(next.start >= previous.start)
    }
    #expect(result.segments.count == sentences.count)
  }
}
