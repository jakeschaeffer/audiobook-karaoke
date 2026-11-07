import Foundation

/// Where a chunk's transcript came from, and how much we trust it.
///
/// This is a first-class field rather than metadata because it *is* the upsert conflict policy:
/// when two producers supply the same `(itemID, chunkIndex)`, the higher `quality` wins. Without it
/// there is no principled answer to "host import arrived for a chunk the phone already
/// transcribed," and the rule ends up bolted on later under pressure.
///
/// It buys three things concretely:
/// - a later host import cleanly superseding on-device chunks (the host's `small` model beats
///   Apple's `SpeechTranscriber` on WER, per `IOS-SPEC.md`),
/// - `CAPTIONS-SPEC.md` stage-2 cleaned prose superseding raw ASR at chunk granularity,
/// - A/B'ing WhisperKit against Apple's API on the same book without wiping either.
public enum TranscriptProvenance: String, Codable, Hashable, Sendable, CaseIterable {
  /// On-device Apple `SpeechTranscriber`. Lowest rank: ~8% WER vs Whisper's ~1%, and it supports no
  /// custom vocabulary, which hurts most on a library full of invented proper nouns.
  case onDeviceApple
  /// On-device WhisperKit. Better than Apple's API, still a smaller model than the host runs.
  case onDeviceWhisperKit
  /// Raw ASR from the host worker (faster-whisper). Word-level timings, no prose cleanup.
  case hostRaw
  /// Host transcript after the stage-2 cleanup pass: book-formatted prose, but only
  /// paragraph-granular timings — see `TranscriptSegment.hasWordTimings`.
  case hostCleaned
  /// ASR cleaned by the on-device foundation model (`CleanupSession`): transcription errors fixed
  /// with the book's title as grounding, dialogue quoted, formatting repaired. Outranks
  /// `hostCleaned` — it starts from the best available ASR text and adds knowledge the host's
  /// cleanup never had — but stays strictly below `ebookAligned`: no model output displaces the
  /// book's own prose. Like `hostCleaned`, it drops word-level timings.
  case onDeviceLLMCleaned
  /// The ebook's own text, timed by aligning it against an ASR pass (`EbookAlignment`). Top rank:
  /// when an epub exists its prose *is* the book — real punctuation, real names — so nothing
  /// auto-transcribed should ever displace it. ASR quality differences stop mattering here; the
  /// ASR was only the timing scaffold.
  case ebookAligned

  /// Higher wins on upsert conflict.
  ///
  /// `hostCleaned` outranks `hostRaw` because it's strictly derived from it and reads better. Note
  /// the deliberate trade: promoting a chunk to `hostCleaned` can *lose word-level timings* for that
  /// chunk, degrading karaoke to paragraph highlight there. That's the cleanup pass's documented
  /// bargain, not a bug — but it's the reason a caller that specifically needs word timings must
  /// check `hasWordTimings` rather than assume rank implies capability.
  public var quality: Int {
    switch self {
    case .onDeviceApple: 0
    case .onDeviceWhisperKit: 1
    case .hostRaw: 2
    case .hostCleaned: 3
    case .onDeviceLLMCleaned: 4
    case .ebookAligned: 5
    }
  }

  /// Whether this producer runs on the phone, spending battery and thermal budget.
  ///
  /// Load-bearing for the store's failure policy: host chunks are cheap to re-fetch over the
  /// tailnet, on-device chunks are not re-derivable without burning the budget again. That
  /// asymmetry — not schema tidiness — is why this store never wipes on error.
  /// `ebookAligned` counts as on-device: the alignment itself is cheap, but its ASR scaffold may
  /// only exist locally, so the rows are treated as irreplaceable too.
  public var isOnDevice: Bool {
    switch self {
    case .onDeviceApple, .onDeviceWhisperKit, .onDeviceLLMCleaned, .ebookAligned: true
    case .hostRaw, .hostCleaned: false
    }
  }
}

/// A completed grid chunk — the unit both producers yield and the only thing the store persists.
///
/// Row existence means completed. There is no `completed` flag and no separate checkpoint record:
/// a chunk is only ever committed once it finalizes, so "this chunk is stored" and "this chunk is
/// done" are the same fact. That collapse is what lets `IOS-SPEC.md`'s checkpoint store and its
/// transcript store be one table instead of two schemas with a merge step between them.
public struct TranscriptChunk: Hashable, Sendable {
  public let itemID: String
  public let chunkIndex: Int
  /// Earliest segment start in this chunk. May sit after the chunk's nominal lower bound when the
  /// audio opens with silence.
  public let minStart: TimeInterval
  /// Latest segment end. May exceed the chunk's nominal upper bound when the final segment straddles
  /// the boundary, so this is recorded rather than derived from the grid.
  public let maxEnd: TimeInterval
  /// Segments in ascending `start` order, each bucketed here by `TranscriptGrid.index(containing:)`.
  public let segments: [TranscriptSegment]
  public let provenance: TranscriptProvenance
  /// Identifies the exact producer, e.g. `"faster-whisper/small"` or `"whisperkit/distil-v3-turbo"`.
  /// Recorded so an engine change is attributable without re-deriving it from `provenance`.
  public let engineID: String

  public init(
    itemID: String,
    chunkIndex: Int,
    segments: [TranscriptSegment],
    provenance: TranscriptProvenance,
    engineID: String
  ) {
    self.itemID = itemID
    self.chunkIndex = chunkIndex
    self.segments = segments.sorted { $0.start < $1.start }
    self.provenance = provenance
    self.engineID = engineID
    // Derive real extent from content, defaulting to the nominal span for an empty chunk (a stretch
    // of pure silence still counts as covered — there is simply nothing said in it).
    let nominal = TranscriptGrid.range(of: chunkIndex)
    minStart = segments.map(\.start).min() ?? nominal.lowerBound
    maxEnd = segments.map(\.end).max() ?? nominal.upperBound
  }
}
