// Excluded from the simulator: iOS-26 SpeechAnalyzer/SpeechTranscriber link against a runtime
// component the simulator doesn't ship, so merely *linking* them makes the whole app fail to launch
// on the sim (dyld can't load them). On-device transcription is a real-hardware feature anyway —
// the 85x throughput and thermal behavior only exist on the device — so the honest state on the
// simulator is "unavailable", which `deviceSupported` reports.
#if os(iOS) && !targetEnvironment(simulator)
import AVFoundation
import Foundation
import Logging
import Speech
import UIKit

/// One on-device transcription run: the whole book (or whatever coverage is missing), foreground,
/// on Apple's `SpeechTranscriber`.
///
/// Measured on this hardware at ~85x realtime with the WWDC-277 concurrent results drain — a
/// 10-hour book is ~7½ minutes of compute — which is why on-device is the *default* path and the
/// host worker (4.5x, but better WER and zero phone battery) is the fallback. Background compute
/// is confirmed unavailable (`BGTaskScheduler.supportedResources` is empty on this device), so the
/// session keeps the screen awake and runs while the app is frontmost; a backgrounded run simply
/// stops making progress until foregrounded again.
///
/// Work lands track-by-track as completed grid chunks with `.onDeviceApple` provenance: the
/// karaoke view reveals text as it's produced, cancellation costs at most the current track, and a
/// re-run resumes from coverage (fully-covered tracks are skipped). When the whole book is covered,
/// and the item has an ebook, the ASR text is then replaced by the book's own prose
/// (`EbookAlignment`, `.ebookAligned` provenance) — the epub is the transcript of record wherever
/// one exists. Finally the transcript is exported in the worker's JSONL shape and offered to the
/// host — write-once server-side, so a host transcript is never clobbered.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class DeviceTranscriptionSession {
  public enum Phase: Equatable, Sendable {
    case idle
    case preparing
    case running
    /// Replacing ASR text with the ebook's own prose (`EbookAlignment`) — brief, but real work
    /// with its own honest status line.
    case aligning
    case uploading
    case finished(uploadedToServer: Bool?)
    case cancelled
    case failed(String)
  }

  public private(set) var phase: Phase = .idle
  /// 0...1 across the audio still to transcribe this run.
  public private(set) var fraction: Double = 0
  public private(set) var currentTrack: Int = 0
  public private(set) var totalTracks: Int = 0
  /// Audio-seconds transcribed per wall-second, live.
  public private(set) var effectiveRate: Double = 0

  public var isActive: Bool {
    switch phase {
    case .preparing, .running, .aligning, .uploading: true
    default: false
    }
  }

  /// True once the stored transcript is the ebook's text rather than raw ASR — either aligned in
  /// this run or found already aligned. Drives the status wording; the transcript content is the
  /// same either way.
  public private(set) var usedEbookText = false

  private let itemID: String
  private let duration: TimeInterval
  private let store: TranscriptStore
  /// Where the audio comes from — local files, a server, anything. The engine has no opinion.
  private let audio: any TranscriptionAudioProvider
  /// Optional remote to offer the finished transcript to; nil (no server) skips the upload phase.
  private let remote: (any RemoteTranscriptService)?
  /// Supplies the item's ebook as plain text (`EbookHTML`-processed), or nil when the item has no
  /// ebook / it can't be fetched. Injected because epub access (Readium, download paths) is app
  /// territory; nil keeps the pure-ASR behavior.
  private let ebookText: (@Sendable () async -> String?)?
  private var runner: Task<Void, Never>?
  private static let logger = Logger(label: "transcription.device")
  private static let alignmentEngineID = "epub-align/v1"

  public init(
    itemID: String,
    duration: TimeInterval,
    store: TranscriptStore,
    audio: any TranscriptionAudioProvider,
    remote: (any RemoteTranscriptService)? = nil,
    ebookText: (@Sendable () async -> String?)? = nil
  ) {
    self.itemID = itemID
    self.duration = duration
    self.store = store
    self.audio = audio
    self.remote = remote
    self.ebookText = ebookText
  }

  public func start() {
    guard !isActive else { return }
    phase = .preparing
    // A held wake, not a direct isIdleTimerDisabled write: a concurrent cleanup or the player's
    // own keep-awake must not lose the screen when this run finishes first.
    ScreenWakeCoordinator.shared.acquire(wakeToken)
    runner = Task { [weak self] in
      await self?.run()
      if let self {
        await MainActor.run { ScreenWakeCoordinator.shared.release(self.wakeToken) }
      }
    }
  }

  /// Committed tracks persist; a later run resumes from coverage.
  public func cancel() {
    runner?.cancel()
    runner = nil
    if isActive { phase = .cancelled }
    ScreenWakeCoordinator.shared.release(wakeToken)
  }

  private var wakeToken: String { "transcribe:\(itemID)" }

  private func run() async {
    do {
      let allTracks = try await audio.tracks(forItem: itemID)
      let coverage = try await store.coverage(forItem: itemID)
      // Resume: a track whose every grid chunk is present needs no work.
      let todo = TranscriptionPlan.tracksNeedingWork(allTracks, coverage: coverage)

      if !todo.isEmpty {
        totalTracks = todo.count
        let audioTotal = todo.reduce(0) { $0 + $1.duration }
        var audioDone = 0.0
        let started = Date()
        phase = .running

        for (position, track) in todo.enumerated() {
          try Task.checkCancellation()
          currentTrack = position + 1

          // Thermal etiquette per the spec: widen spacing on .serious, stop on .critical. At 85x
          // this is expected to be theoretical, but a sustained whole-book run is exactly where
          // it would surface.
          switch ProcessInfo.processInfo.thermalState {
          case .critical:
            throw TranscriptionError.deviceTooHot
          case .serious:
            try await Task.sleep(for: .seconds(30))
          default:
            break
          }

          let media = try await audio.audio(forItem: itemID, track: track)
          // Providers own their files' lifetimes: a temporary download is ours to clean up; a
          // downloaded book's original absolutely is not.
          defer {
            if media.isTemporary { try? FileManager.default.removeItem(at: media.url) }
          }

          let segments = try await transcribe(
            fileAt: media.url,
            track: track,
            progress: { [weak self] inTrackSeconds in
              guard let self else { return }
              let done = audioDone + min(inTrackSeconds, track.duration)
              self.fraction = min(1, done / max(audioTotal, 1))
              let wall = Date().timeIntervalSince(started)
              if wall > 1 { self.effectiveRate = done / wall }
            }
          )
          let chunks = TranscriptChunker.bucket(
            segments,
            itemID: itemID,
            provenance: .onDeviceApple,
            engineID: "apple/SpeechTranscriber"
          )
          try await store.commit(contentsOf: chunks)

          audioDone += track.duration
          fraction = min(1, audioDone / max(audioTotal, 1))
          Self.logger.info(
            "device transcribed track \(track.index): \(segments.count) segments"
          )
        }

        try await backfillSilence(transcribed: todo)
      }

      // Runs on the already-covered path too: "Transcribe on iPhone" on a fully-ASR'd book is
      // how an epub that arrived later still becomes the transcript.
      try await alignToEbookIfAvailable()
      phase = .uploading
      phase = .finished(uploadedToServer: await uploadIfComplete())
    } catch is CancellationError {
      phase = .cancelled
    } catch {
      Self.logger.error("device transcription failed: \(error)")
      phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
  }

  /// Empty rows for chunks the run proved silent — see `TranscriptionPlan.silentBackfillChunks`
  /// for the reasoning (it's the testable half of this).
  private func backfillSilence(transcribed tracks: [TrackInfo]) async throws {
    let coverage = try await store.coverage(forItem: itemID)
    let empties = TranscriptionPlan.silentBackfillChunks(
      transcribed: tracks,
      coverage: coverage,
      duration: duration
    ).map { index in
      TranscriptChunk(
        itemID: itemID,
        chunkIndex: index,
        segments: [],
        provenance: .onDeviceApple,
        engineID: "apple/SpeechTranscriber"
      )
    }
    guard !empties.isEmpty else { return }
    try await store.commit(contentsOf: empties)
    Self.logger.info("backfilled \(empties.count) silent chunks")
  }

  /// If the item has an ebook, replace the ASR text with the book's own prose, timed by the ASR.
  ///
  /// The upsert conflict rule (`.ebookAligned` outranks everything) makes this idempotent and
  /// safe to run whether the ASR came from this run, an earlier one, or a host import. Alignment
  /// *refusal* — wrong edition, no shared text — is logged and swallowed: the ASR transcript is
  /// the correct output then, and the run must still finish and upload it. Chunks that get no
  /// aligned sentence (a publisher intro the book doesn't contain) keep their ASR rows, which is
  /// the honest reading for audio the book never printed.
  private func alignToEbookIfAvailable() async throws {
    guard let ebookText else { return }

    let counts = try await store.provenanceCounts(forItem: itemID)
    let total = counts.values.reduce(0, +)
    guard total > 0 else { return }
    if counts[.ebookAligned] == total {
      usedEbookText = true
      return
    }

    phase = .aligning
    guard let text = await ebookText(), !text.isEmpty else { return }
    try Task.checkCancellation()
    let asr = try await store.segments(forItem: itemID, in: 0...duration)
    guard !asr.isEmpty else { return }

    do {
      // Off the main actor: a whole book is ~60k tokens a side and the session lives on @MainActor.
      let result = try await Task.detached(priority: .userInitiated) {
        try EbookAlignment.align(bookText: text, asr: asr)
      }.value
      let chunks = TranscriptChunker.bucket(
        result.segments,
        itemID: itemID,
        provenance: .ebookAligned,
        engineID: Self.alignmentEngineID
      )
      try await store.commit(contentsOf: chunks)
      usedEbookText = true
      Self.logger.info(
        "ebook alignment: \(result.segments.count) sentences, match \(Int(result.matchedFraction * 100))%, \(result.anchorCount) anchors"
      )
    } catch let error as EbookAlignmentError {
      Self.logger.warning("ebook alignment declined, keeping ASR: \(error)")
    }
  }

  /// Offer the finished book to the remote (when one is configured) so it can serve every other
  /// client. Only when coverage is actually complete — a partial upload would set
  /// `has_transcript` at 5% and mislead every consumer that trusts it. Returns nil when not
  /// attempted (no remote, or incomplete).
  private func uploadIfComplete() async -> Bool? {
    guard let remote else { return nil }
    do {
      let coverage = try await store.coverage(forItem: itemID)
      let total = TranscriptGrid.chunkCount(forDuration: duration)
      guard total > 0, coverage.chunks.count >= total else { return nil }

      let segments = try await store.segments(forItem: itemID, in: 0...duration)
      guard !segments.isEmpty else { return nil }
      // Label the upload with the weakest tier it contains — claiming ebookAligned for a book
      // that's only partly aligned would let it wrongly displace a better server transcript.
      let tiers = try await store.chunkProvenances(forItem: itemID)
      let weakest = tiers.values.min { $0.quality < $1.quality } ?? .onDeviceApple
      let stored = try await remote.upload(
        itemID: itemID,
        jsonl: try TranscriptExport.jsonl(segments),
        provenance: weakest
      )
      Self.logger.info(
        stored
          ? "uploaded transcript to host (\(segments.count) segments)"
          : "host already has a transcript; upload skipped"
      )
      return stored
    } catch {
      Self.logger.warning("transcript upload failed (book remains local): \(error)")
      return nil
    }
  }

  // MARK: - SpeechTranscriber

  private func transcribe(
    fileAt url: URL,
    track: TrackInfo,
    progress: @escaping @MainActor (TimeInterval) -> Void
  ) async throws -> [TranscriptSegment] {
    let transcriber = SpeechTranscriber(
      locale: Locale(identifier: "en-US"),
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: [.audioTimeRange]
    )
    if let installation = try await AssetInventory.assetInstallationRequest(
      supporting: [transcriber])
    {
      try await installation.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      // 'dta?'/'typ?' OSStatus soup helps nobody in a status banner; say what actually matters.
      throw TranscriptionError.audioOpenFailed(detail: "\(error.localizedDescription)")
    }

    // The load-bearing detail: drain results concurrently with analysis. A serial drain is what
    // made the one published number for this hardware ~14x too slow.
    async let collected = Self.collectSegments(
      from: transcriber,
      trackStart: track.start,
      trackIndex: track.index,
      progress: progress
    )
    let lastSample = try await analyzer.analyzeSequence(from: file)
    if let lastSample {
      try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await collected
  }

  private static func collectSegments(
    from transcriber: SpeechTranscriber,
    trackStart: TimeInterval,
    trackIndex: Int,
    progress: @escaping @MainActor (TimeInterval) -> Void
  ) async throws -> [TranscriptSegment] {
    var segments: [TranscriptSegment] = []
    var lastReported = Date.distantPast

    for try await result in transcriber.results {
      let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }

      var words: [TranscriptWord] = []
      var earliest = TimeInterval.greatestFiniteMagnitude
      var latest = 0.0
      for run in result.text.runs {
        guard let range = run.audioTimeRange else { continue }
        let start = range.start.seconds
        let end = range.end.seconds
        earliest = min(earliest, start)
        latest = max(latest, end)
        let word = String(result.text[run.range].characters)
        guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        words.append(
          TranscriptWord(text: word, start: trackStart + start, end: trackStart + end)
        )
      }
      guard earliest < latest else { continue }

      segments.append(
        TranscriptSegment(
          // Millisecond-derived id: unique (two segments can't start in the same ms) and stable
          // across re-runs of the same audio.
          seg: Int(((trackStart + earliest) * 1000).rounded()),
          track: trackIndex,
          start: trackStart + earliest,
          end: trackStart + latest,
          text: text,
          words: words.isEmpty ? nil : words
        )
      )

      let now = Date()
      if now.timeIntervalSince(lastReported) > 0.3 {
        lastReported = now
        await progress(latest)
      }
    }
    return segments
  }
}
#endif
