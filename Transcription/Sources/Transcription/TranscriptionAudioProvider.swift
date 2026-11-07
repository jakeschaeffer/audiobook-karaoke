import Foundation

/// Audio ready for the transcriber, plus the one fact the session must know about it: whether the
/// file is the provider's temporary copy (delete after transcribing) or a caller-owned original —
/// a downloaded book's track — that the session must leave alone. Before this flag existed the
/// session deleted unconditionally, which was fine only because audio always arrived as a download.
public struct TranscriptionAudio: Sendable {
  public let url: URL
  public let isTemporary: Bool

  public init(url: URL, isTemporary: Bool) {
    self.url = url
    self.isTemporary = isTemporary
  }
}

/// Where `DeviceTranscriptionSession` gets its audio. The engine consumes tracks and files; it has
/// no opinion about where they come from — local downloads, a direct server fetch, or (in this
/// fork) the captions daemon's authenticated proxy. Mirrors the proven `ebookText:` injection
/// pattern: app territory supplies the closure-shaped dependency, the engine stays portable.
///
/// Providers own container validation: whatever they return must be Core-Audio-readable
/// (`AudioFileType.isCoreAudioReadable`), throwing `TranscriptionError.unsupportedAudioFormat`
/// otherwise — an `.ogg` book fails the `AVAudioFile` open with OSStatus soup if it gets that far.
public protocol TranscriptionAudioProvider: Sendable {
  /// The book's track map, book-absolute starts, ascending.
  func tracks(forItem itemID: String) async throws -> [TrackInfo]
  /// Audio for one track, ready for `AVAudioFile`.
  func audio(forItem itemID: String, track: TrackInfo) async throws -> TranscriptionAudio
}
