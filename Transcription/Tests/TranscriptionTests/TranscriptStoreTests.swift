import Foundation
import SwiftData
import Testing

@testable import Transcription

/// Store tests run against an in-memory container so they exercise the real schema, predicates, and
/// upsert path without touching the App Group on disk.
private func makeStore() throws -> TranscriptStore {
  TranscriptStore(modelContainer: try TestContainers.makeInMemory())
}

private func segment(_ seg: Int, start: TimeInterval, text: String = "text") -> TranscriptSegment {
  TranscriptSegment(
    seg: seg,
    track: 1,
    start: start,
    end: start + 2,
    text: text,
    words: [TranscriptWord(text: " w", start: start, end: start + 0.3)]
  )
}

@Suite("Transcript store")
struct TranscriptStoreTests {
  @Test("Commit then read round-trips segments through the blob column")
  func commitAndRead() async throws {
    let store = try makeStore()
    let chunk = TranscriptChunk(
      itemID: "book",
      chunkIndex: 0,
      segments: [segment(1, start: 10), segment(2, start: 20)],
      provenance: .hostRaw,
      engineID: "faster-whisper/small"
    )
    try await store.commit(chunk)

    let read = try await store.segments(forItem: "book", in: 0...300)
    #expect(read.map(\.seg) == [1, 2])
    #expect(read[0].hasWordTimings)
    #expect(try await store.coverage(forItem: "book").chunks == [0])
    #expect(try await store.segmentCount(forItem: "book") == 2)
  }

  @Test("Re-committing the same chunk is a no-op, not a duplicate")
  func commitIsIdempotent() async throws {
    let store = try makeStore()
    let chunk = TranscriptChunk(
      itemID: "book",
      chunkIndex: 0,
      segments: [segment(1, start: 10)],
      provenance: .hostRaw,
      engineID: "e"
    )
    try await store.commit(chunk)
    try await store.commit(chunk)
    try await store.commit(chunk)

    #expect(try await store.segmentCount(forItem: "book") == 1)
    #expect(try await store.coverage(forItem: "book").chunks == [0])
  }

  @Test("Higher-quality provenance supersedes lower; lower never overwrites higher")
  func provenanceConflictRule() async throws {
    let store = try makeStore()
    // The phone transcribed this chunk just-in-time...
    try await store.commit(
      TranscriptChunk(
        itemID: "book",
        chunkIndex: 0,
        segments: [segment(1, start: 10, text: "on device")],
        provenance: .onDeviceApple,
        engineID: "apple"
      )
    )
    // ...then the host's better transcript arrives. It should win.
    try await store.commit(
      TranscriptChunk(
        itemID: "book",
        chunkIndex: 0,
        segments: [segment(1, start: 10, text: "host raw")],
        provenance: .hostRaw,
        engineID: "faster-whisper/small"
      )
    )
    var read = try await store.segments(forItem: "book", in: 0...300)
    #expect(read[0].text == "host raw")

    // A later on-device pass must NOT clobber the better host text.
    try await store.commit(
      TranscriptChunk(
        itemID: "book",
        chunkIndex: 0,
        segments: [segment(1, start: 10, text: "on device again")],
        provenance: .onDeviceApple,
        engineID: "apple"
      )
    )
    read = try await store.segments(forItem: "book", in: 0...300)
    #expect(read[0].text == "host raw")
  }

  @Test("Reads are trimmed to the window, not the whole chunk")
  func readsTrimToWindow() async throws {
    let store = try makeStore()
    try await store.commit(
      TranscriptChunk(
        itemID: "book",
        chunkIndex: 0,
        segments: [segment(1, start: 10), segment(2, start: 100), segment(3, start: 250)],
        provenance: .hostRaw,
        engineID: "e"
      )
    )
    let read = try await store.segments(forItem: "book", in: 90...150)
    #expect(read.map(\.seg) == [2])
  }

  @Test("A read spanning chunks stitches them in order")
  func readAcrossChunks() async throws {
    let store = try makeStore()
    for index in 0..<3 {
      try await store.commit(
        TranscriptChunk(
          itemID: "book",
          chunkIndex: index,
          segments: [segment(index * 10, start: Double(index) * 300 + 5)],
          provenance: .hostRaw,
          engineID: "e"
        )
      )
    }
    let read = try await store.segments(forItem: "book", in: 0...900)
    #expect(read.map(\.seg) == [0, 10, 20])
    #expect(try await store.coverage(forItem: "book").chunks == [0, 1, 2])
  }

  @Test("Items are isolated from each other")
  func itemsAreIsolated() async throws {
    let store = try makeStore()
    try await store.commit(
      TranscriptChunk(
        itemID: "a",
        chunkIndex: 0,
        segments: [segment(1, start: 10)],
        provenance: .hostRaw,
        engineID: "e"
      )
    )
    try await store.commit(
      TranscriptChunk(
        itemID: "b",
        chunkIndex: 0,
        segments: [segment(2, start: 10)],
        provenance: .hostRaw,
        engineID: "e"
      )
    )
    #expect(try await store.segments(forItem: "a", in: 0...300).map(\.seg) == [1])
    #expect(try await store.coverage(forItem: "b").chunks == [0])

    try await store.delete(itemID: "a")
    #expect(try await store.coverage(forItem: "a").isEmpty)
    #expect(try await store.coverage(forItem: "b").chunks == [0])
  }

  @Test("An empty chunk is still coverage — silence gets a row")
  func emptyChunkIsCoverage() async throws {
    let store = try makeStore()
    try await store.commit(
      TranscriptChunk(
        itemID: "book",
        chunkIndex: 5,
        segments: [],
        provenance: .hostRaw,
        engineID: "e"
      )
    )
    // Otherwise the scheduler would ask for this chunk forever.
    #expect(try await store.coverage(forItem: "book").chunks == [5])
    #expect(try await store.segments(forItem: "book", in: 1500...1800).isEmpty)
  }

  @Test("Batch commit matches single commit")
  func batchCommit() async throws {
    let store = try makeStore()
    let chunks = (0..<20).map { index in
      TranscriptChunk(
        itemID: "book",
        chunkIndex: index,
        segments: [segment(index, start: Double(index) * 300 + 1)],
        provenance: .hostRaw,
        engineID: "e"
      )
    }
    try await store.commit(contentsOf: chunks)
    #expect(try await store.coverage(forItem: "book").chunks.count == 20)
    // And it's idempotent too.
    try await store.commit(contentsOf: chunks)
    #expect(try await store.segmentCount(forItem: "book") == 20)
  }
}
