import Foundation

/// The fixed chunk grid that both transcript producers write onto.
///
/// Everything stored is bucketed into fixed 300s spans of book-absolute time. One stored row per
/// chunk means ~240 rows for a 20h book (Goblet: 243) and ~4k rows for this library's 17 audio
/// items — small enough that bulk insert is a loop rather than a batch.
///
/// The grid exists to make the two producers converge. The host importer re-chunks a whole book
/// onto it and the on-device engine emits one chunk at a time at the playhead; because both land on
/// the same boundaries, a host chunk and an on-device chunk are the same row shape, so there is one
/// read path and one notion of coverage, and the two can interleave freely within a book.
///
/// **The grid is why chunk size cannot be a backoff knob.** `IOS-SPEC.md` says to back off on
/// `.serious` thermal state by "widening the chunk interval"; that means spacing chunks further
/// apart in time or shortening lookahead depth, *not* shrinking a chunk. A variable-size chunk
/// doesn't land on the grid, which breaks idempotent upsert and coverage. Changing `span` later
/// invalidates every stored chunk and has no cheap migration, so it is deliberately a constant.
public enum TranscriptGrid {
  /// Chunk width in book-absolute seconds.
  ///
  /// 300s sits at the top of the spec's 2–5 min chunk range, so an engine chunk *is* a grid chunk
  /// and no re-chunking is needed on the on-device path. At ~97 segments per 300s (measured on
  /// Goblet) a chunk's encoded blob is ~10KB — well under the threshold where external storage
  /// would earn its complexity.
  public static let span: TimeInterval = 300

  /// The chunk a segment belongs to, keyed on its `start`.
  ///
  /// Bucketing on `start` (never on `end`, never on overlap) is what makes assignment total and
  /// deterministic: every segment lands in exactly one chunk even when it straddles a boundary.
  /// A straddler goes to the earlier chunk — e.g. Goblet's seg 7000 (21598.22–21600.28) is chunk
  /// 71, not 72 — and the chunk's stored `maxEnd` records that it reaches past its nominal end.
  public static func index(containing time: TimeInterval) -> Int {
    Int((max(0, time) / span).rounded(.down))
  }

  /// Nominal half-open time span of a chunk. A chunk's *actual* extent can exceed this on the
  /// upper side when its last segment straddles the boundary; see `TranscriptChunk.maxEnd`.
  public static func range(of index: Int) -> Range<TimeInterval> {
    let lower = TimeInterval(index) * span
    return lower..<(lower + span)
  }

  /// Every chunk index touching `range`, inclusive of the chunk containing `upperBound`.
  ///
  /// Callers reading a time window use this to turn a float range into indexed integer lookups,
  /// which keeps reads off float predicates entirely.
  public static func indices(covering range: ClosedRange<TimeInterval>) -> ClosedRange<Int> {
    index(containing: range.lowerBound)...index(containing: range.upperBound)
  }

  /// Number of chunks needed to cover a book of `duration`.
  public static func chunkCount(forDuration duration: TimeInterval) -> Int {
    guard duration > 0 else { return 0 }
    return index(containing: duration.nextDown) + 1
  }
}
