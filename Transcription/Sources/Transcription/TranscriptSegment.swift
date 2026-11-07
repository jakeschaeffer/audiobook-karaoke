import Foundation

/// One word with its book-absolute timing.
///
/// Wire format is the caption worker's compact form: `{"w": " Harry", "s": 9137.2, "e": 9137.6}`.
/// `text` preserves the leading space the ASR emits — concatenating `text` across a segment's
/// words reproduces the segment text verbatim, so the karaoke view can lay out words without
/// re-inserting separators and guessing at punctuation spacing.
public struct TranscriptWord: Codable, Hashable, Sendable {
  public let text: String
  public let start: TimeInterval
  public let end: TimeInterval

  public init(text: String, start: TimeInterval, end: TimeInterval) {
    self.text = text
    self.start = start
    self.end = end
  }

  private enum CodingKeys: String, CodingKey {
    case text = "w"
    case start = "s"
    case end = "e"
  }
}

/// One ASR segment — the unit the worker emits and the reader renders.
///
/// `start`/`end` are **book-absolute** seconds (track start offset + in-track time), not
/// track-relative, so a segment can be compared against the playhead directly.
public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
  /// Worker-assigned segment index, unique and ordered within a book.
  public let seg: Int
  /// Source track this segment came from. **1-indexed**, matching the daemon's `/tracks` map
  /// and `/audio?track=N` — there is no track 0.
  public let track: Int
  public let start: TimeInterval
  public let end: TimeInterval
  public let text: String
  /// Word-level timings. Absent when the segment came from a cleanup pass, which is only
  /// paragraph-granular — see `hasWordTimings`.
  public let words: [TranscriptWord]?

  public var id: Int { seg }

  /// Whether this segment can drive word-level karaoke highlighting.
  ///
  /// `/captions` serves cleaned prose when a cleanup pass has run and raw ASR otherwise. Cleaned
  /// paragraphs inherit `start`/`end` from the segments they cover but carry no `words[]`, so the
  /// karaoke view must fall back to highlighting the whole segment for these.
  public var hasWordTimings: Bool {
    !(words ?? []).isEmpty
  }

  public var timeRange: ClosedRange<TimeInterval> {
    // Guard against a zero- or negative-width segment, which ClosedRange traps on.
    start...Swift.max(start, end)
  }

  public init(
    seg: Int,
    track: Int,
    start: TimeInterval,
    end: TimeInterval,
    text: String,
    words: [TranscriptWord]?
  ) {
    self.seg = seg
    self.track = track
    self.start = start
    self.end = end
    self.text = text
    self.words = words
  }

  /// The word under `time`, for the karaoke highlight.
  ///
  /// Word ranges are contiguous but ASR stamps carry ±0.2–0.5s of error, so a strict containment
  /// test leaves gaps where nothing is highlighted. Returns the last word starting at or before
  /// `time` instead, which keeps a word lit through any gap until the next one begins.
  public func word(at time: TimeInterval) -> TranscriptWord? {
    guard let words, !words.isEmpty else { return nil }
    guard time >= words[0].start else { return nil }

    var low = 0
    var high = words.count - 1
    var match = 0
    while low <= high {
      let mid = (low + high) / 2
      if words[mid].start <= time {
        match = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return words[match]
  }
}
