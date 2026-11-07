import Foundation
import Testing

@testable import Transcription

@Suite("Transcription planning")
struct TranscriptionPlanTests {
  private func track(_ index: Int, start: TimeInterval, duration: TimeInterval) -> TrackInfo {
    TrackInfo(index: index, start: start, duration: duration)
  }

  @Test("A fully covered track is skipped; a partially covered one is not")
  func resumeSkipsCoveredTracks() {
    // Track 1 spans chunks 0-1 (0-600s), track 2 spans chunks 2-3 (600-1200s).
    let tracks = [track(1, start: 0, duration: 600), track(2, start: 600, duration: 600)]
    let coverage = TranscriptCoverage(chunks: [0, 1])

    let todo = TranscriptionPlan.tracksNeedingWork(tracks, coverage: coverage)
    #expect(todo.map(\.index) == [2])
  }

  @Test("No coverage means every track needs work, in order")
  func emptyCoverageKeepsAll() {
    let tracks = [track(1, start: 0, duration: 300), track(2, start: 300, duration: 300)]
    let todo = TranscriptionPlan.tracksNeedingWork(tracks, coverage: TranscriptCoverage(chunks: []))
    #expect(todo.map(\.index) == [1, 2])
  }

  @Test("A short track inside one chunk is judged by that chunk alone")
  func shortTrackSingleChunk() {
    let tracks = [track(1, start: 30, duration: 100)]
    #expect(
      TranscriptionPlan.tracksNeedingWork(tracks, coverage: TranscriptCoverage(chunks: [0])).isEmpty
    )
    #expect(
      TranscriptionPlan.tracksNeedingWork(tracks, coverage: TranscriptCoverage(chunks: [1])).count
        == 1
    )
  }

  @Test("Uncovered chunks inside transcribed spans are silence; outside them, absence")
  func backfillDistinguishesSilenceFromAbsence() {
    // One transcribed track covering 0-900s (chunks 0-2); the book runs to 1500s (chunks 0-4).
    // Chunk 1 produced no speech (silence); chunks 3-4 were never transcribed (absence).
    let tracks = [track(1, start: 0, duration: 900)]
    let coverage = TranscriptCoverage(chunks: [0, 2])

    let empties = TranscriptionPlan.silentBackfillChunks(
      transcribed: tracks,
      coverage: coverage,
      duration: 1500
    )
    #expect(empties == [1])
  }

  @Test("A silent tail inside the final track is backfilled to the book's duration")
  func silentTailBackfills() {
    // Track spans the whole 890s book (chunks 0-2, the last one short).
    let tracks = [track(1, start: 0, duration: 890)]
    let coverage = TranscriptCoverage(chunks: [0, 1])

    let empties = TranscriptionPlan.silentBackfillChunks(
      transcribed: tracks,
      coverage: coverage,
      duration: 890
    )
    #expect(empties == [2])
  }

  @Test("Nothing to backfill when coverage is complete")
  func completeCoverageBackfillsNothing() {
    let tracks = [track(1, start: 0, duration: 600)]
    let coverage = TranscriptCoverage(chunks: [0, 1])
    let empties = TranscriptionPlan.silentBackfillChunks(
      transcribed: tracks,
      coverage: coverage,
      duration: 600
    )
    #expect(empties.isEmpty)
  }
}

@Suite("Track wire mapping and store paths")
struct DecouplingSeamTests {
  @Test("Daemon wire keys map into the engine's TrackInfo")
  func decodeTracksMapsWireKeys() throws {
    let json = Data(#"{"tracks":[{"i":3,"start":12.5,"dur":300},{"i":4,"start":312.5,"dur":10}]}"#.utf8)
    let tracks = try HostTranscriptSource.decodeTracks(json)
    #expect(
      tracks == [
        TrackInfo(index: 3, start: 12.5, duration: 300),
        TrackInfo(index: 4, start: 312.5, duration: 10),
      ]
    )
  }

  @Test("Nil app group falls back to Application Support; the layout suffix is stable")
  func databaseURLFallback() {
    let url = TranscriptStore.databaseURL(serverID: "srv-1", appGroup: nil)
    #expect(url.path.hasSuffix("/srv-1/Transcripts.sqlite"))
    #expect(url.path.contains("Application Support"))
  }

  @Test("The injected app group lands in the path with the same per-server layout")
  func databaseURLHonorsAppGroup() {
    // macOS resolves containerURL for any group id (unlike iOS, which returns nil for
    // unprovisioned ones), which makes the honored-group property directly assertable here.
    let url = TranscriptStore.databaseURL(serverID: "srv-1", appGroup: "group.example.test")
    #expect(url.path.contains("group.example.test"))
    #expect(url.path.hasSuffix("/srv-1/Transcripts.sqlite"))
  }

  @Test("Legacy-store adoption merges by quality and retires the legacy files")
  func legacyAdoptionMergesAndRetires() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "legacy-adopt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyURL = dir.appending(path: "Transcripts.sqlite")

    func chunk(_ index: Int, _ provenance: TranscriptProvenance, text: String) -> TranscriptChunk {
      TranscriptChunk(
        itemID: "book",
        chunkIndex: index,
        segments: [
          TranscriptSegment(
            seg: index,
            track: 1,
            start: TimeInterval(index) * TranscriptGrid.span + 1,
            end: TimeInterval(index) * TranscriptGrid.span + 2,
            text: text,
            words: nil
          )
        ],
        provenance: provenance,
        engineID: "test"
      )
    }

    // The pre-move store: one cleaned chunk, one raw chunk.
    let legacyStore = TranscriptStore(modelContainer: try TestContainers.makeOnDisk(at: legacyURL))
    try await legacyStore.commit(contentsOf: [
      chunk(0, .onDeviceLLMCleaned, text: "cleaned"),
      chunk(1, .hostRaw, text: "old raw"),
    ])

    // The new store re-imported chunk 0 at a *lower* tier and gained a brand-new chunk 2.
    let store = TranscriptStore(modelContainer: try TestContainers.makeInMemory())
    try await store.commit(contentsOf: [
      chunk(0, .hostRaw, text: "reimported raw"),
      chunk(2, .hostRaw, text: "new raw"),
    ])

    await store.adoptLegacyStore(try TestContainers.makeOnDisk(at: legacyURL), at: legacyURL)

    // Cleaned beats the re-import; the legacy raw chunk arrives; the new chunk survives.
    let tiers = try await store.chunkProvenances(forItem: "book")
    #expect(tiers == [0: .onDeviceLLMCleaned, 1: .hostRaw, 2: .hostRaw])
    let texts = try await store.segments(forItem: "book", in: 0...3 * TranscriptGrid.span)
      .map(\.text)
    #expect(texts == ["cleaned", "old raw", "new raw"])

    // The legacy family is renamed, so the adoption can never run twice.
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(FileManager.default.fileExists(atPath: legacyURL.path + ".migrated"))
  }
}
