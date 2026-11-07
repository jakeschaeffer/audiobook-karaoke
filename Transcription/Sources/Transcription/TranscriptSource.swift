import Foundation

/// A producer of completed grid chunks.
///
/// Both transcript paths conform to this one protocol rather than the store growing a write API per
/// path. The host importer fetches `/captions`, re-buckets onto the grid, yields ~240 chunks and
/// finishes; the on-device engine yields one chunk each time a 5-minute span finalizes, driven by the
/// playhead, indefinitely. The store's consumer code is identical for both — that identity is the test
/// of whether this seam is right. If a producer needs its own commit path, the seam is wrong.
///
/// Bulk import is therefore not a special case; it is the same `commit` in a tighter transaction.
public protocol TranscriptSource: Sendable {
  var provenance: TranscriptProvenance { get }
  var engineID: String { get }

  /// Produce chunks for `itemID` covering `chunks`, in ascending index order.
  ///
  /// The caller — a scheduler, not the engine — decides which indices to ask for. An on-device engine
  /// is handed one index at a time based on `TranscriptCoverage.nextUncovered(after:duration:)`; the
  /// importer is handed everything missing. Direction of control matters: an engine that picks its own
  /// work can't be steered by the playhead, and can't be told to skip what's already stored.
  func chunks(
    forItem itemID: String,
    indices: [Int]
  ) -> AsyncThrowingStream<TranscriptChunk, Error>
}

/// Groups segments onto the fixed grid.
///
/// Shared by every `TranscriptSource` so host and on-device chunks are bucketed identically —
/// the property that lets them interleave in one book.
public enum TranscriptChunker {
  /// Bucket `segments` by `TranscriptGrid.index(containing:)` on each segment's `start`.
  ///
  /// Deduplicates by `seg` first. This is required, not defensive: the daemon's `/captions` filters on
  /// *overlap* (`s.end > from and s.start < to`), so a segment straddling a window boundary is
  /// returned by both adjacent fetches. Verified on Goblet — seg 7000 (21598.22–21600.28) comes back
  /// from both `[21300,21600)` and `[21600,21900)`. Without the dedupe it would be stored twice and
  /// counted twice.
  public static func bucket(
    _ segments: [TranscriptSegment],
    itemID: String,
    provenance: TranscriptProvenance,
    engineID: String,
    restrictedTo indices: Set<Int>? = nil
  ) -> [TranscriptChunk] {
    var seen = Set<Int>()
    var byChunk: [Int: [TranscriptSegment]] = [:]

    for segment in segments {
      guard seen.insert(segment.seg).inserted else { continue }
      let index = TranscriptGrid.index(containing: segment.start)
      if let indices, !indices.contains(index) { continue }
      byChunk[index, default: []].append(segment)
    }

    return byChunk.keys.sorted().map { index in
      TranscriptChunk(
        itemID: itemID,
        chunkIndex: index,
        segments: byChunk[index] ?? [],
        provenance: provenance,
        engineID: engineID
      )
    }
  }
}
