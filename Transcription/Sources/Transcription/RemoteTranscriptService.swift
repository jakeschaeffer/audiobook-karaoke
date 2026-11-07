import Foundation

/// A remote party that can serve and accept transcripts. Entirely optional: the engine and every
/// surface are fully functional with none (`nil`), which is the expected configuration anywhere
/// without a personal transcript server. This fork implements it with the abs-session daemon; a
/// future Audiobookshelf-native transcript API could implement it for everyone.
///
/// Deliberately *not* here: job orchestration (request/cancel/poll a server-side transcription).
/// That's a property of one particular server, not of "a remote transcript store" — the fork
/// layers it on via `RemoteTranscriptionJobService` in its daemon glue.
public protocol RemoteTranscriptService: Sendable {
  /// JIT chunk import for windows the local store is missing, or nil when the remote can't serve
  /// text (upload-only remotes are conceivable).
  var source: (any TranscriptSource)? { get }

  /// The highest tier the remote already holds for this item, nil when unknown or none. Callers
  /// use it to skip pointless uploads; unknown means "try — the server will refuse same-or-worse".
  func bestProvenance(forItem itemID: String) async -> TranscriptProvenance?

  /// Offer a complete transcript. True when this upload became the remote's transcript of record;
  /// false when the remote kept what it had (same-or-better tier) — benign, not an error.
  @discardableResult
  func upload(itemID: String, jsonl: Data, provenance: TranscriptProvenance) async throws -> Bool
}
