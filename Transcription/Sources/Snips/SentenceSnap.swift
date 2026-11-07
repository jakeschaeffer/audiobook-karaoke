import Foundation
import Transcription

/// The light "intelligence" behind a capture: nudge In to the start of a sentence and Out to the end
/// of the one being spoken, when a sentence edge is close enough that the move is clearly what the
/// listener meant. Stored segments are sentence-sized on every tier this app holds, so a segment edge
/// is a sentence edge. Nothing here reaches further than a few seconds; the chosen length still
/// decides the span.
public enum SentenceSnap {
  /// How far In may move, either way, to land on a sentence start.
  public static let inReachMs = 8_000
  /// How far past the tap Out may move to finish the sentence being spoken.
  public static let outReachMs = 6_000

  public struct Result: Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int
  }

  public static func snap(
    startMs: Int,
    endMs: Int,
    floorMs: Int,
    segments: [TranscriptSegment]
  ) -> Result {
    let starts = segments.map { Int(($0.start * 1000).rounded()) }.sorted()
    var start = startMs
    // The nearest sentence start within reach, never below the floor (the heard-from point) and never
    // at or past Out.
    let candidate =
      starts
      .filter { abs($0 - startMs) <= inReachMs && $0 >= floorMs && $0 < endMs }
      .min { abs($0 - startMs) != abs($1 - startMs) ? abs($0 - startMs) < abs($1 - startMs) : $0 < $1 }
    if let candidate { start = candidate }

    var end = endMs
    // The sentence being spoken at the tap: extend Out to its end when that is close.
    if let current = segments.first(where: { $0.start * 1000 <= Double(endMs) && $0.end * 1000 > Double(endMs) }) {
      let segmentEnd = Int((current.end * 1000).rounded())
      if segmentEnd - endMs <= outReachMs { end = segmentEnd }
    }
    return Result(startMs: start, endMs: max(end, start + 1_000))
  }
}
