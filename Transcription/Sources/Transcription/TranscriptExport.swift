import Foundation

/// Serializes segments into the caption worker's JSONL wire format — the exact shape
/// `transcribe.py` emits and `PUT /transcripts/{item_id}` validates: one object per line with
/// `seg`, `track`, book-absolute `start`/`end`, `text`, and compact `words`.
public enum TranscriptExport {
  public static func jsonl(_ segments: [TranscriptSegment]) throws -> Data {
    var out = Data()
    let encoder = JSONEncoder()
    for segment in segments.sorted(by: { $0.start < $1.start }) {
      let row = Row(
        seg: segment.seg,
        track: segment.track,
        start: rounded(segment.start),
        end: rounded(segment.end),
        text: segment.text,
        words: (segment.words ?? []).map {
          Row.Word(w: $0.text, s: rounded($0.start), e: rounded($0.end))
        }
      )
      out.append(try encoder.encode(row))
      out.append(0x0A)
    }
    return out
  }

  /// Two decimal places, matching the worker's own rounding — keeps uploaded files diffable
  /// against host-produced ones.
  private static func rounded(_ value: TimeInterval) -> Double {
    (value * 100).rounded() / 100
  }

  private struct Row: Encodable {
    struct Word: Encodable {
      let w: String
      let s: Double
      let e: Double
    }

    let seg: Int
    let track: Int
    let start: Double
    let end: Double
    let text: String
    let words: [Word]
  }
}
