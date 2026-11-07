import Foundation
import Testing

@testable import Transcription

@Suite("Grid bucketing")
struct TranscriptGridTests {
  @Test("Segments bucket by start, so a straddler lands in the earlier chunk")
  func straddlerGoesToEarlierChunk() {
    // Goblet's real seg 7000: starts at 21598.22, ends at 21600.28, crossing the 21600 boundary
    // between chunks 71 and 72.
    #expect(TranscriptGrid.index(containing: 21598.22) == 71)
    #expect(TranscriptGrid.index(containing: 21600.28) == 72)

    let straddler = TranscriptSegment(
      seg: 7000,
      track: 16,
      start: 21598.22,
      end: 21600.28,
      text: "straddles",
      words: nil
    )
    let chunks = TranscriptChunker.bucket(
      [straddler],
      itemID: "i",
      provenance: .hostRaw,
      engineID: "e"
    )
    #expect(chunks.count == 1)
    #expect(chunks[0].chunkIndex == 71)
    // The chunk records that it reaches past its nominal end rather than clipping the segment.
    #expect(chunks[0].maxEnd == 21600.28)
    #expect(TranscriptGrid.range(of: 71).upperBound == 21600)
  }

  @Test("Duplicate segments from overlapping fetch windows are deduped by seg id")
  func dedupesBySegID() {
    // The daemon filters /captions on overlap (end > from AND start < to), so a straddling segment
    // comes back from both adjacent windows. Verified live on Goblet seg 7000.
    let s = TranscriptSegment(
      seg: 7000,
      track: 16,
      start: 21598.22,
      end: 21600.28,
      text: "once",
      words: nil
    )
    let chunks = TranscriptChunker.bucket(
      [s, s, s],
      itemID: "i",
      provenance: .hostRaw,
      engineID: "e"
    )
    #expect(chunks.count == 1)
    #expect(chunks[0].segments.count == 1)
  }

  @Test("Bucketing can be restricted to requested indices")
  func restrictsToRequestedIndices() {
    let a = TranscriptSegment(seg: 1, track: 1, start: 10, end: 12, text: "a", words: nil)
    let b = TranscriptSegment(seg: 2, track: 1, start: 310, end: 312, text: "b", words: nil)
    let chunks = TranscriptChunker.bucket(
      [a, b],
      itemID: "i",
      provenance: .hostRaw,
      engineID: "e",
      restrictedTo: [0]
    )
    #expect(chunks.map(\.chunkIndex) == [0])
  }

  @Test("Chunk count covers the whole book without a spurious trailing chunk")
  func chunkCountIsExact() {
    #expect(TranscriptGrid.chunkCount(forDuration: 0) == 0)
    #expect(TranscriptGrid.chunkCount(forDuration: 1) == 1)
    // Exactly on a boundary: 300s is one chunk, not two.
    #expect(TranscriptGrid.chunkCount(forDuration: 300) == 1)
    #expect(TranscriptGrid.chunkCount(forDuration: 301) == 2)
    // Goblet: 72830.2s.
    #expect(TranscriptGrid.chunkCount(forDuration: 72830.2) == 243)
  }

  @Test("Indices covering a window include both endpoints' chunks")
  func indicesCoverWindow() {
    #expect(TranscriptGrid.indices(covering: 0...299) == 0...0)
    #expect(TranscriptGrid.indices(covering: 299...301) == 0...1)
    #expect(TranscriptGrid.indices(covering: 22756...22766) == 75...75)
  }
}
