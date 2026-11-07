import Foundation

/// Which chunks of a book have transcript on this device.
///
/// Coverage is a set of grid chunk indices, derived from the stored rows — never a separate stored
/// fact that could drift out of sync with them, and never a watermark.
///
/// **Why not a watermark.** The worker reports a single `covered_secs`, which is lossless *for the
/// worker* because a batch job walks tracks in order and only ever grows coverage forward from 0.
/// On-device just-in-time transcription has no such property: it runs at the playhead, and seeking
/// is arbitrary. Listen to chapter 20, transcribe 15 minutes ahead, seek back to chapter 3 — coverage
/// is now genuinely disjoint. A scalar cannot express that hole, so a watermark client must either
/// treat 20 as the high-water mark and skip chapter 3 (the reader renders nothing exactly where the
/// user is listening) or reset to the playhead and re-burn the chapter-20 work on the next forward
/// seek. Both are real user-visible failures, so the client models coverage as a set.
///
/// The host's watermark is still the right model for the *host*; see `RemoteCoverage`. Keeping the
/// two named apart is deliberate — conflating them is the mistake the server contract invites.
public struct TranscriptCoverage: Equatable, Sendable {
  /// Grid indices with a committed chunk.
  public let chunks: Set<Int>

  public init(chunks: Set<Int> = []) {
    self.chunks = chunks
  }

  public var isEmpty: Bool { chunks.isEmpty }

  /// Transcribed seconds, counted in whole grid chunks.
  ///
  /// Approximate by construction: the final chunk of a book is partial, and a chunk's real extent can
  /// exceed its nominal span. Good enough for a progress readout; use `isCovered(_:)` for decisions.
  public func coveredDuration(cappedTo duration: TimeInterval? = nil) -> TimeInterval {
    let raw = TimeInterval(chunks.count) * TranscriptGrid.span
    guard let duration else { return raw }
    return min(raw, duration)
  }

  /// Fraction of a book covered, clamped to 0...1.
  ///
  /// `duration == 0` means an ebook-only item — 31 of this library's 48 items — which has no audio to
  /// transcribe. Report 0 rather than dividing by zero.
  public func fraction(of duration: TimeInterval) -> Double {
    guard duration > 0 else { return 0 }
    let total = TranscriptGrid.chunkCount(forDuration: duration)
    guard total > 0 else { return 0 }
    return min(1, Double(chunks.count) / Double(total))
  }

  public func contains(time: TimeInterval) -> Bool {
    chunks.contains(TranscriptGrid.index(containing: time))
  }

  /// Whether every chunk touching `range` is present — i.e. the reader can render it without holes.
  public func isCovered(_ range: ClosedRange<TimeInterval>) -> Bool {
    TranscriptGrid.indices(covering: range).allSatisfy(chunks.contains)
  }

  /// The next chunk index at or after `time` that has no transcript, bounded by `duration`.
  ///
  /// This is the just-in-time scheduler's central question, and the reason coverage must be a set:
  /// the scheduler asks the store what to do next, then hands a specific chunk to the engine. The
  /// engine never decides what to transcribe. Returns nil when everything from `time` to the end of
  /// the book is already covered.
  public func nextUncovered(after time: TimeInterval, duration: TimeInterval) -> Int? {
    let total = TranscriptGrid.chunkCount(forDuration: duration)
    guard total > 0 else { return nil }
    let start = min(max(0, TranscriptGrid.index(containing: time)), total - 1)
    for index in start..<total where !chunks.contains(index) {
      return index
    }
    return nil
  }

  /// Uncovered chunk indices in `range`, in playback order — the scheduler's work queue.
  public func missingChunks(in range: ClosedRange<TimeInterval>) -> [Int] {
    TranscriptGrid.indices(covering: range).filter { !chunks.contains($0) }
  }
}

/// The host's view of a book's transcript, as reported by `GET /status?item_id` on the worker.
///
/// Distinct from `TranscriptCoverage` on purpose. This is a contiguous-from-zero watermark, which is
/// correct for the host and wrong for the client, and it drives one thing only: the remote-job UI's
/// decide-between offer-the-reader / resume-the-job / fall-back.
public struct RemoteCoverage: Equatable, Sendable {
  /// True as soon as *any* transcript exists — including a cancelled job's 5% JSONL. Never a
  /// completeness signal on its own; a client that treats it as one renders the first few minutes and
  /// then silently nothing.
  public let hasTranscript: Bool
  public let segments: Int
  /// Book-absolute watermark of host coverage.
  public let coveredSecs: TimeInterval
  /// Tier of the transcript on the host, or nil when the server predates provenance versioning
  /// (or holds no transcript). Nil means "unknown" — treat an upload as worthwhile and let the
  /// server 409 it.
  public let provenance: TranscriptProvenance?

  public init(
    hasTranscript: Bool,
    segments: Int,
    coveredSecs: TimeInterval,
    provenance: TranscriptProvenance? = nil
  ) {
    self.hasTranscript = hasTranscript
    self.segments = segments
    self.coveredSecs = coveredSecs
    self.provenance = provenance
  }

  /// Trailing audio the host will never cover, because silence produces no segment to cover it.
  ///
  /// Goblet — the one fully-transcribed book — reports `covered_secs` 72820.42 against a `duration`
  /// of 72830.2: a 9.8s shortfall. A strict `coveredSecs >= duration` test would therefore report the
  /// canonical complete fixture as incomplete forever, and would offer to "resume" a finished job.
  static let completenessTolerance: TimeInterval = 30

  /// Whether the host's transcript covers essentially the whole book.
  public func isComplete(duration: TimeInterval) -> Bool {
    guard duration > 0, hasTranscript else { return false }
    return coveredSecs >= duration - Self.completenessTolerance
  }

  public func fraction(of duration: TimeInterval) -> Double {
    guard duration > 0 else { return 0 }
    return min(1, max(0, coveredSecs / duration))
  }
}
