import Foundation
import SnipCore
import Transcription

/// Reads the words of a span out of stored transcript segments. Pure: tested without a store.
public enum TranscriptExcerpt {
  public struct Result: Equatable, Sendable {
    public let text: String
    /// The lowest-quality tier among the chunks the span touched (the text to improve on later).
    public let tier: TranscriptProvenance?
  }

  /// The tokens whose midpoints lie inside `[startMs, endMs]`, joined as they were displayed.
  /// Nil when no stored segment overlaps the span.
  public static func excerpt(
    from segments: [TranscriptSegment],
    startMs: Int,
    endMs: Int,
    tiers: [Int: TranscriptProvenance] = [:]
  ) -> Result? {
    let span = SpanPoints.Span(startMs: startMs, endMs: endMs)
    // Tokens carry their own leading space within a segment; segments are joined with one.
    var pieces: [String] = []
    for segment in segments where segment.end * 1000 >= Double(startMs) && segment.start * 1000 <= Double(endMs) {
      let inside = segment.timedTokens().filter { token in
        SpanPoints.wordInSpan(
          startMs: Int((token.start * 1000).rounded()),
          endMs: Int((token.end * 1000).rounded()),
          span: span
        )
      }
      if !inside.isEmpty { pieces.append(inside.map(\.text).joined()) }
    }
    let text = pieces.joined(separator: " ")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    let range = TimeInterval(startMs) / 1000...TimeInterval(endMs) / 1000
    let touched = TranscriptGrid.indices(covering: range)
    let tier = touched.compactMap { tiers[$0] }.min { $0.quality < $1.quality }
    return Result(text: text, tier: tier)
  }
}
