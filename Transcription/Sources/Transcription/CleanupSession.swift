#if canImport(FoundationModels) && os(iOS)
import Foundation
import FoundationModels
import Logging
import UIKit

/// Cleans raw ASR chunks with the on-device foundation model and commits them as
/// `.onDeviceLLMCleaned` — the tier between the host's cleanup and the ebook's own text.
///
/// The shape deliberately mirrors `DeviceTranscriptionSession`: one cancellable runner Task,
/// per-unit thermal and cancellation checks, chunk-granular commits so interruption anywhere costs
/// nothing, and resume derived from the store (`chunkProvenances`) rather than a watermark. The
/// difference is pace. ASR runs at ~85x realtime; generation is ~1:1 tokens in/out at tens of
/// tokens per second, so a full book is *hours* of ANE time, not minutes. That is why the queue is
/// **playhead-first**: the listener needs the next fifteen minutes cleaned, not the whole book, and
/// every chunk that commits is immediately rendered by the karaoke views.
///
/// What the model is asked to do — and *only* this: fix mis-transcriptions (grounded by the book's
/// title and author, which is how "Bagamon and Crouch" becomes Bagman), restore punctuation and
/// casing, and put quotation marks around dialogue. Segment boundaries and timings pass through
/// untouched; word timings drop (`hostCleaned`'s documented bargain applies here too). A cleaned
/// line that no longer resembles its source — the failure mode of every generative rewrite — is
/// rejected per-segment by a token-overlap guard, keeping the ASR text for that line.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class CleanupSession {
  public enum Phase: Equatable, Sendable {
    case idle
    case running
    case uploading
    /// `uploadedToServer` is nil when the book isn't fully covered (nothing was attempted).
    case finished(uploadedToServer: Bool?)
    case cancelled
    case failed(String)
  }

  public private(set) var phase: Phase = .idle
  /// Cleanable chunks completed this run, over the run's total.
  public private(set) var chunksDone = 0
  public private(set) var chunksTotal = 0
  /// Lines the guard rejected (kept as ASR). A high count means the model is drifting on this book.
  public private(set) var rejectedLines = 0

  public var fraction: Double {
    chunksTotal > 0 ? Double(chunksDone) / Double(chunksTotal) : 0
  }

  public var statusText: String? {
    switch phase {
    case .idle:
      nil
    case .running:
      String(localized: "Cleaning up text · \(chunksDone)/\(chunksTotal)", bundle: .module)
    case .uploading:
      String(localized: "Saving cleaned text to server…", bundle: .module)
    case .finished(let uploaded):
      uploaded == true
        ? String(localized: "Cleaned text saved to server", bundle: .module)
        : String(localized: "Text cleaned up", bundle: .module)
    case .cancelled:
      String(localized: "Cleanup stopped — progress kept", bundle: .module)
    case .failed(let message):
      String(localized: "Cleanup failed: \(message)", bundle: .module)
    }
  }

  /// Whether this device can run cleanup at all: Apple Intelligence enabled, model downloaded.
  /// `.unavailable` is ordinary (ineligible hardware, disabled setting) — callers hide the feature.
  public static var isSupported: Bool {
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
  }

  private let itemID: String
  private let duration: TimeInterval
  /// Grounding for proper nouns, e.g. "Harry Potter and the Goblet of Fire by J.K. Rowling".
  private let bookContext: String?
  private let store: TranscriptStore
  /// Optional remote to offer the cleaned book to; nil (no server) skips the upload phase.
  private let remote: (any RemoteTranscriptService)?
  private let onChunkCleaned: (@MainActor () -> Void)?

  private var runner: Task<Void, Never>?
  private static let logger = Logger(label: "transcription.cleanup")

  /// Segments per model request. One 5-minute chunk holds ~40–90 short segments; batches keep each
  /// request comfortably inside the on-device model's small context window.
  private static let batchSize = 30
  /// Reject a cleaned line whose token overlap with its source falls below this — it stopped being
  /// a cleanup and became a rewrite.
  private static let minTokenOverlap = 0.5

  public init(
    itemID: String,
    duration: TimeInterval,
    bookContext: String? = nil,
    store: TranscriptStore,
    remote: (any RemoteTranscriptService)? = nil,
    onChunkCleaned: (@MainActor () -> Void)? = nil
  ) {
    self.itemID = itemID
    self.duration = duration
    self.bookContext = bookContext
    self.store = store
    self.remote = remote
    self.onChunkCleaned = onChunkCleaned
  }

  /// Begin cleaning, prioritizing the chunk containing `position` and proceeding forward before
  /// wrapping — the listener's next quarter hour beats the book's first chapter.
  public func start(from position: TimeInterval = 0) {
    guard runner == nil else { return }
    phase = .running
    // Same rationale as transcription: generation halts when the app backgrounds anyway
    // (no background compute), so hold the screen awake for the run — via the coordinator, so a
    // concurrent transcription or the player's keep-awake preference survives this run ending.
    ScreenWakeCoordinator.shared.acquire(wakeToken)
    runner = Task { [weak self] in
      await self?.run(from: position)
      self?.releaseWake()
    }
  }

  public func cancel() {
    // Cancelling a run that already finished must not overwrite its final phase — a cancel racing
    // completion used to report "stopped" for a successful, uploaded run.
    guard phase == .running || phase == .uploading else { return }
    runner?.cancel()
    runner = nil
    phase = .cancelled
    releaseWake()
  }

  private var wakeToken: String { "cleanup:\(itemID)" }

  private func releaseWake() {
    ScreenWakeCoordinator.shared.release(wakeToken)
  }

  private func run(from position: TimeInterval) async {
    do {
      let tiers = try await store.chunkProvenances(forItem: itemID)
      // Only raw ASR tiers have something to gain. hostCleaned is already prose; ebookAligned is
      // the book itself — the model must never touch either.
      let cleanable =
        tiers
        .filter { $0.value.quality <= TranscriptProvenance.hostRaw.quality }
        .keys.sorted()
      guard !cleanable.isEmpty else {
        phase = .finished(uploadedToServer: nil)
        return
      }

      // Playhead-first: the tail from the current chunk, then the wrapped head.
      let pivot = TranscriptGrid.index(containing: position)
      let queue = cleanable.filter { $0 >= pivot } + cleanable.filter { $0 < pivot }
      chunksTotal = queue.count
      chunksDone = 0

      let session = try makeSession()
      for index in queue {
        try Task.checkCancellation()
        try Self.checkThermals()
        try await clean(chunkIndex: index, session: session)
        chunksDone += 1
        onChunkCleaned?()
      }

      phase = .uploading
      let uploaded = await uploadIfComplete()
      phase = .finished(uploadedToServer: uploaded)
    } catch is CancellationError {
      phase = .cancelled
    } catch {
      Self.logger.error("cleanup failed: \(error)")
      // The human-readable description, not the enum dump — this string lands verbatim in the
      // sheet's banner (DeviceTranscriptionSession got this right from day one).
      phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
    runner = nil
  }

  // MARK: - Model

  @Generable
  struct CleanedBatch {
    @Guide(description: "Exactly one entry per input line: same id, original order.")
    var lines: [Line]

    @Generable
    struct Line {
      @Guide(description: "The id of the input line this cleans.")
      var id: Int
      @Guide(description: "The cleaned text of that line.")
      var text: String
    }
  }

  private func makeSession() throws -> LanguageModelSession {
    guard Self.isSupported else { throw TranscriptionError.cleanupUnavailable }
    let book = bookContext.map { " The book is \($0)." } ?? ""
    return LanguageModelSession(
      instructions: """
        You clean up audiobook transcription errors.\(book) Each input line is one \
        transcribed utterance, formatted as "id<TAB>text". For every line: fix words the \
        transcriber misheard (especially character and place names from this book), fix \
        capitalization and punctuation, and put double quotation marks around spoken dialogue. \
        Preserve the meaning and wording otherwise — do not summarize, do not merge or split \
        lines, do not add or remove content. Return every line with its original id.
        """
    )
  }

  private func clean(chunkIndex: Int, session: LanguageModelSession) async throws {
    let nominal = TranscriptGrid.range(of: chunkIndex)
    let originals = try await store.segments(
      forItem: itemID,
      in: nominal.lowerBound...nominal.upperBound
    )
    .filter { TranscriptGrid.index(containing: $0.start) == chunkIndex }
    guard !originals.isEmpty else { return }

    var cleanedText: [Int: String] = [:]
    for batch in originals.chunked(into: Self.batchSize) {
      try Task.checkCancellation()
      let prompt =
        batch
        .map { "\($0.seg)\t\($0.text)" }
        .joined(separator: "\n")
      do {
        let response = try await session.respond(to: prompt, generating: CleanedBatch.self)
        for line in response.content.lines {
          cleanedText[line.id] = line.text
        }
      } catch {
        // One refused or overlong batch is not a failed run — those lines keep their ASR text.
        Self.logger.warning("batch failed in chunk \(chunkIndex): \(error)")
      }
    }

    let cleaned = originals.map { segment in
      let candidate = cleanedText[segment.seg]
      guard let candidate, Self.acceptable(candidate, original: segment.text) else {
        if candidate != nil { rejectedLines += 1 }
        return segment
      }
      return TranscriptSegment(
        seg: segment.seg,
        track: segment.track,
        start: segment.start,
        end: segment.end,
        text: candidate,
        words: nil
      )
    }

    let chunks = TranscriptChunker.bucket(
      cleaned,
      itemID: itemID,
      provenance: .onDeviceLLMCleaned,
      engineID: "afm/cleanup-v1"
    )
    try await store.commit(contentsOf: chunks)
  }

  /// The drift guard. Normalized-token containment: enough of the original's words must survive
  /// into the cleaned line. Punctuation, casing, and quoting are free; rewriting is not.
  static func acceptable(_ cleaned: String, original: String) -> Bool {
    let cleanedTokens = tokens(cleaned)
    let originalTokens = tokens(original)
    guard !cleanedTokens.isEmpty else { return originalTokens.isEmpty }
    guard !originalTokens.isEmpty else { return false }
    let kept = originalTokens.filter(cleanedTokens.contains).count
    let overlap = Double(kept) / Double(originalTokens.count)
    let lengthRatio = Double(cleaned.count) / Double(max(original.count, 1))
    return overlap >= minTokenOverlap && (0.5...2.0).contains(lengthRatio)
  }

  private static func tokens(_ text: String) -> Set<String> {
    Set(
      text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    )
  }

  private static func checkThermals() throws {
    switch ProcessInfo.processInfo.thermalState {
    case .critical: throw TranscriptionError.deviceTooHot
    default: break
    }
  }

  /// Same contract as transcription's upload: whole books only, and the remote's per-tier
  /// write-once decides whether this replaces what it has (a refusal is benign). Nil remote =
  /// nothing attempted, which is the whole configuration for server-less installs.
  private func uploadIfComplete() async -> Bool? {
    guard let remote else { return nil }
    do {
      let coverage = try await store.coverage(forItem: itemID)
      let total = TranscriptGrid.chunkCount(forDuration: duration)
      guard total > 0, coverage.chunks.count >= total else { return nil }

      let tiers = try await store.chunkProvenances(forItem: itemID)
      let weakest = tiers.values.min { $0.quality < $1.quality } ?? .onDeviceLLMCleaned
      if let held = await remote.bestProvenance(forItem: itemID),
        held.quality >= weakest.quality
      {
        return false
      }

      let segments = try await store.segments(forItem: itemID, in: 0...duration)
      guard !segments.isEmpty else { return nil }
      return try await remote.upload(
        itemID: itemID,
        jsonl: try TranscriptExport.jsonl(segments),
        provenance: weakest
      )
    } catch {
      Self.logger.warning("cleaned upload failed (book remains local): \(error)")
      return nil
    }
  }
}

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: Swift.max(size, 1)).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
#endif
