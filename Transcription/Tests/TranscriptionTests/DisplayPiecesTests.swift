import Foundation
import Testing

@testable import Transcription

@Suite("Display pieces for size-budgeted karaoke surfaces")
struct DisplayPiecesTests {
  /// The run-on sentence that motivated this (Goblet, cleaned tier, 266 characters).
  static let runOn =
    "In the meantime, life became even worse for Harry within the confines of the castle, for Rita Skeeter had published her piece about the Tri-Wizard tournament, and it had turned out to be not so much a report on the tournament as a highly colored life story of Harry."

  /// Word-timed segment from `text`: 0.3s per word starting at `start`.
  static func timed(_ text: String, start: TimeInterval = 100) -> TranscriptSegment {
    let parts = text.split(separator: " ").map(String.init)
    let words = parts.enumerated().map { index, word in
      TranscriptWord(
        text: " " + word,
        start: start + Double(index) * 0.3,
        end: start + Double(index + 1) * 0.3
      )
    }
    return TranscriptSegment(
      seg: 42,
      track: 3,
      start: start,
      end: start + Double(parts.count) * 0.3,
      text: text,
      words: words
    )
  }

  @Test("A segment within the budget comes back untouched")
  func shortIsUntouched() {
    let segment = Self.timed("He can't avoid us forever.")
    #expect(segment.displayPieces(maxCharacters: 60) == [segment])
  }

  @Test("Pieces respect the budget, keep every word in order, and keep word timings")
  func runOnSplits() {
    let segment = Self.timed(Self.runOn)
    let pieces = segment.displayPieces(maxCharacters: 60)

    #expect(pieces.count >= 5)
    #expect(pieces.allSatisfy { $0.text.count <= 60 })
    #expect(pieces.map(\.text).joined(separator: " ") == Self.runOn)
    #expect(pieces.flatMap { $0.words ?? [] } == segment.words)
    // Contiguous in time, spanning exactly the original segment.
    #expect(pieces.first?.start == segment.start)
    #expect(pieces.last?.end == segment.end)
    for (earlier, later) in zip(pieces, pieces.dropFirst()) {
      #expect(earlier.end <= later.start)
    }
    // Identity is the caller's business.
    #expect(pieces.allSatisfy { $0.seg == 42 && $0.track == 3 })
  }

  @Test("Cuts prefer punctuation near the balanced point over the exact midpoint")
  func prefersPunctuation() {
    // The comma sits a few words before the midpoint; a pure-balance cut would land after "the".
    let text = "He had put the golden egg upstairs, in his trunk, and hadn't opened it since the party."
    let pieces = Self.timed(text).displayPieces(maxCharacters: 60)
    #expect(pieces.map(\.text).first == "He had put the golden egg upstairs, in his trunk,")

    // At the cover's budget every cut in the run-on lands on a clause boundary.
    let cover = Self.timed(Self.runOn).displayPieces(maxCharacters: 120)
    #expect(cover.dropLast().allSatisfy { $0.text.hasSuffix(",") })
  }

  @Test("Pieces are balanced: just over the budget splits into halves, not a stray word")
  func balanced() {
    // 71 characters with the budget at 60: a greedy cut would leave ~11 characters behind.
    let text = "Harry seized Dobby by the back of his tie and pulled him from the table."
    let pieces = Self.timed(text).displayPieces(maxCharacters: 60)
    #expect(pieces.count == 2)
    #expect(pieces.allSatisfy { $0.text.count >= 25 })
  }

  @Test("Segments without word timings split too, with interpolated times")
  func untimedInterpolates() {
    let segment = TranscriptSegment(
      seg: 7,
      track: 1,
      start: 10,
      end: 30,
      text: Self.runOn,
      words: nil
    )
    let pieces = segment.displayPieces(maxCharacters: 80)
    #expect(pieces.count >= 4)
    #expect(pieces.allSatisfy { $0.words == nil && $0.text.count <= 80 })
    #expect(pieces.map(\.text).joined(separator: " ") == Self.runOn)
    #expect(pieces.first?.start == 10)
    #expect(pieces.last?.end == 30)
    for (earlier, later) in zip(pieces, pieces.dropFirst()) {
      #expect(earlier.start < later.start)
      #expect(later.start > 10 && later.start < 30)
    }
  }

  @Test("A single word longer than the budget stands alone rather than looping")
  func overlongWord() {
    let text = "Supercalifragilisticexpialidocious indeed"
    let pieces = Self.timed(text).displayPieces(maxCharacters: 10)
    #expect(pieces.map(\.text) == ["Supercalifragilisticexpialidocious", "indeed"])
  }
}
