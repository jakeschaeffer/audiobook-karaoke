import Foundation
import SwiftData
import Testing

@testable import Transcription

/// A whole-book import against the live daemon. Slower than the rest of the live suite (~40 HTTP round
/// trips), so it's gated separately:
///
///     TRANSCRIPTION_LIVE_FULL=1 swift test --filter FullImport
///
/// This is the test of the design's central bet: that chunk-granular rows make a 20h book's transcript
/// a loop rather than a bulk-insert problem.
private let fullEnabled = ProcessInfo.processInfo.environment["TRANSCRIPTION_LIVE_FULL"] == "1"

private let goblet = "f4f72906-0548-45b2-b75a-44d08826e458"
private let gobletDuration: TimeInterval = 72830.2
/// From `GET /status?item_id=<goblet>` on the worker.
private let expectedSegments = 23467

@Suite("FullImport", .enabled(if: fullEnabled))
struct FullImportTests {
  @Test("Imports all of Goblet and accounts for every segment")
  func importsWholeBook() async throws {
    let store = TranscriptStore(modelContainer: try TestContainers.makeInMemory())
    let source = HostTranscriptSource(endpoint: .live)

    let total = TranscriptGrid.chunkCount(forDuration: gobletDuration)
    #expect(total == 243)

    let clock = ContinuousClock()
    var committed = 0
    let elapsed = try await clock.measure {
      for try await chunk in source.chunks(forItem: goblet, indices: Array(0..<total)) {
        try await store.commit(chunk)
        committed += 1
      }
    }

    let coverage = try await store.coverage(forItem: goblet)
    let stored = try await store.segmentCount(forItem: goblet)

    print(
      """

      ── Full Goblet import ────────────────────────────────
        chunks committed : \(committed) of \(total)
        coverage         : \(coverage.chunks.count) chunks, \
      \(String(format: "%.2f", coverage.fraction(of: gobletDuration) * 100))%
        segments stored  : \(stored) (worker reports \(expectedSegments))
        wall clock       : \(elapsed)
      ──────────────────────────────────────────────────────

      """
    )

    // Every chunk the book has must be covered — the reader can then render anywhere without holes.
    #expect(coverage.isCovered(0...gobletDuration))
    #expect(coverage.fraction(of: gobletDuration) == 1)

    // The importer must neither lose nor duplicate segments. Dedupe across ~40 overlapping fetch
    // windows is the thing most likely to break, and it would show up here as an inflated count.
    #expect(stored == expectedSegments)
  }

  @Test("Re-importing the whole book changes nothing")
  func reimportIsIdempotent() async throws {
    let store = TranscriptStore(modelContainer: try TestContainers.makeInMemory())
    let source = HostTranscriptSource(endpoint: .live)

    // A narrow slice is enough to prove the property; the full run above proves the scale.
    let indices = Array(100..<110)
    for try await chunk in source.chunks(forItem: goblet, indices: indices) {
      try await store.commit(chunk)
    }
    let first = try await store.segmentCount(forItem: goblet)

    for try await chunk in source.chunks(forItem: goblet, indices: indices) {
      try await store.commit(chunk)
    }
    let second = try await store.segmentCount(forItem: goblet)

    #expect(first == second)
    #expect(try await store.coverage(forItem: goblet).chunks == Set(indices))
  }
}
