import Foundation

extension TranscriptSegment {
  /// This segment cut into pieces of at most `maxCharacters` each, for surfaces with a fixed size
  /// budget (the landscape reading display, the player's cover square) where one run-on sentence
  /// would otherwise shrink to fit or overflow its frame.
  ///
  /// Cuts fall between words, preferring punctuation — a clause boundary reads as a natural pause —
  /// and the pieces are balanced, so a segment just over the limit splits into two halves rather
  /// than a full piece and a stray word. Every piece keeps its words' own timings (no word is ever
  /// re-timed); segments without word timings get piece times interpolated by character offset.
  /// A single word longer than the limit becomes a piece of its own.
  ///
  /// Pieces keep this segment's `seg` — callers that need distinct identities assign them.
  /// Returns `[self]` when no cut is needed.
  public func displayPieces(maxCharacters: Int) -> [TranscriptSegment] {
    let tokens = displayTokens()
    let total = tokens.reduce(0) { $0 + $1.text.count }
    guard maxCharacters > 0, total > maxCharacters, tokens.count > 1 else { return [self] }

    var ranges: [Range<Int>] = []
    var first = 0
    while first < tokens.count {
      let remaining = tokens[first...].reduce(0) { $0 + $1.text.count }
      if remaining <= maxCharacters {
        ranges.append(first..<tokens.count)
        break
      }
      let pieceCount = (remaining + maxCharacters - 1) / maxCharacters
      let target = Double(remaining) / Double(pieceCount)

      var best = first
      var bestCost = Double.infinity
      var length = 0
      for last in first..<(tokens.count - 1) {
        length += tokens[last].text.count
        if length > maxCharacters, last > first { break }
        let punctuationBonus = Self.breakStrength(after: tokens[last].text)
        let cost = abs(Double(length) - target) / target - punctuationBonus
        if cost < bestCost {
          bestCost = cost
          best = last
        }
      }
      ranges.append(first..<(best + 1))
      first = best + 1
    }

    return ranges.enumerated().map { index, range in
      let slice = Array(tokens[range])
      let isFirst = index == 0
      let isLast = index == ranges.count - 1
      let pieceText = slice.map(\.text).joined().trimmingCharacters(in: .whitespaces)
      return TranscriptSegment(
        seg: seg,
        track: track,
        start: isFirst ? start : slice[0].start,
        end: isLast ? end : slice[slice.count - 1].end,
        text: pieceText,
        words: words == nil ? nil : slice.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }
      )
    }
  }

  /// How much a cut after this token is worth, as a fraction of the target length it may drift:
  /// a sentence end best, a clause mark next, a plain word gap nothing.
  private static func breakStrength(after token: String) -> Double {
    let trimmed = token.trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
    guard let last = trimmed.last else { return 0 }
    if ".!?…".contains(last) { return 0.5 }
    if ",;:—–".contains(last) || trimmed.hasSuffix("--") { return 0.35 }
    return 0
  }

  /// The segment as timed tokens: its words when it has them, otherwise whitespace-split text
  /// with times interpolated across the segment by character offset. Either way, concatenating
  /// the tokens' text reproduces what the karaoke views render.
  ///
  /// Public for the snip excerpt: a span's quote is the tokens whose midpoints fall inside it
  /// (docs/cross-repo-snips-plan.md §1.4), on measured or interpolated times alike.
  public func timedTokens() -> [TranscriptWord] {
    displayTokens()
  }

  private func displayTokens() -> [TranscriptWord] {
    if let words, !words.isEmpty { return words }
    let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let texts = parts.enumerated().map { $0.offset == 0 ? $0.element : " " + $0.element }
    let total = max(1, texts.reduce(0) { $0 + $1.count })
    let span = max(0, end - start)
    var offset = 0
    return texts.map { piece in
      let tokenStart = start + span * Double(offset) / Double(total)
      offset += piece.count
      let tokenEnd = start + span * Double(offset) / Double(total)
      return TranscriptWord(text: piece, start: tokenStart, end: tokenEnd)
    }
  }
}
