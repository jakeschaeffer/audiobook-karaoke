import Foundation
import SwiftData
import Testing

@testable import Transcription

/// Tests that hit the real abs-session daemon over the tailnet.
///
/// Gated behind `TRANSCRIPTION_LIVE=1` so the suite stays hermetic by default — these need the box up
/// and the Mac on the tailnet. Run with:
///
///     TRANSCRIPTION_LIVE=1 swift test --filter LiveDaemon
///
/// They're worth keeping rather than doing once by hand: they're the only thing that verifies our
/// decode against what the daemon actually emits, rather than against a fixture we wrote ourselves.
private let liveEnabled = ProcessInfo.processInfo.environment["TRANSCRIPTION_LIVE"] == "1"

/// Harry Potter and the Goblet of Fire — the one fully-transcribed book. 20.2h, 23,467 segments.
private let goblet = "f4f72906-0548-45b2-b75a-44d08826e458"
private let gobletDuration: TimeInterval = 72830.2

@Suite("LiveDaemon", .enabled(if: liveEnabled))
struct LiveDaemonTests {
  @Test("Decodes real /captions output with word timings")
  func decodesLiveCaptions() async throws {
    let source = HostTranscriptSource(endpoint: .live)
    let segments = try await source.captions(itemID: goblet, from: 22756, to: 22766)

    #expect(!segments.isEmpty)
    let withWords = segments.filter(\.hasWordTimings)
    #expect(!withWords.isEmpty, "expected word-level timings from the raw host transcript")

    // Book-absolute, not track-relative: a segment near 22756s must report ~22756, not an offset
    // within track 16.
    #expect(segments.contains { $0.start > 22000 })
    // Tracks are 1-indexed on this daemon; there is no track 0.
    #expect(segments.allSatisfy { $0.track >= 1 })
  }

  @Test("The daemon filters on overlap, so adjacent windows share a straddling segment")
  func adjacentWindowsOverlap() async throws {
    // This is the property that forces dedupe-by-seg in the importer. If the daemon ever switched to
    // start-based filtering this test would fail and the dedupe could be simplified — so it documents
    // a live contract, not just our code.
    let source = HostTranscriptSource(endpoint: .live)
    let boundary: TimeInterval = 21600
    let before = try await source.captions(itemID: goblet, from: boundary - 300, to: boundary)
    let after = try await source.captions(itemID: goblet, from: boundary, to: boundary + 300)

    let shared = Set(before.map(\.seg)).intersection(after.map(\.seg))
    #expect(!shared.isEmpty, "expected at least one segment straddling the boundary")

    let straddler = try #require(before.first { shared.contains($0.seg) })
    #expect(straddler.start < boundary)
    #expect(straddler.end > boundary)
  }

  @Test("Imports a real slice of Goblet end-to-end into the store")
  func importsSliceEndToEnd() async throws {
    let store = TranscriptStore(modelContainer: try TestContainers.makeInMemory())
    let source = HostTranscriptSource(endpoint: .live)

    // Chunks 71-73 straddle the 21600 boundary we know has a straddling segment.
    let wanted = [71, 72, 73]
    var imported = 0
    for try await chunk in source.chunks(forItem: goblet, indices: wanted) {
      try await store.commit(chunk)
      imported += 1
    }

    #expect(imported == wanted.count)
    let coverage = try await store.coverage(forItem: goblet)
    #expect(coverage.chunks == Set(wanted))

    // Read back across the boundary and confirm no duplicate seg survived the overlap fetch.
    let segments = try await store.segments(forItem: goblet, in: 21300...22200)
    #expect(!segments.isEmpty)
    let ids = segments.map(\.seg)
    #expect(ids.count == Set(ids).count, "duplicate segments leaked through the importer")
    #expect(ids == ids.sorted(), "segments must come back in playback order")

    // The straddler is stored exactly once, in the earlier chunk.
    let straddlers = segments.filter { $0.start < 21600 && $0.end > 21600 }
    #expect(straddlers.count == 1)

    // Word-level highlight works on real data at a real playhead.
    let atPlayhead = try await store.segments(forItem: goblet, in: 21598...21600)
    let word = atPlayhead.compactMap { $0.word(at: 21599) }.first
    #expect(word != nil, "expected a word under the playhead for the karaoke view")
  }

  @Test("Coverage of a partial import correctly reports incomplete")
  func partialImportIsIncomplete() async throws {
    let store = TranscriptStore(modelContainer: try TestContainers.makeInMemory())
    let source = HostTranscriptSource(endpoint: .live)

    for try await chunk in source.chunks(forItem: goblet, indices: [0, 1]) {
      try await store.commit(chunk)
    }
    let coverage = try await store.coverage(forItem: goblet)

    // Two of 243 chunks. The reader must not claim the book is readable.
    #expect(!coverage.isCovered(0...gobletDuration))
    #expect(coverage.fraction(of: gobletDuration) < 0.02)
    // The scheduler's next question resolves to the first hole.
    #expect(coverage.nextUncovered(after: 0, duration: gobletDuration) == 2)
  }
}
