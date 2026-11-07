import Foundation
import Models
import Snips
import Transcription

/// The one place the snip layer reads "what is playing": the speaker first (it may be mid-book with
/// nothing loaded on the phone), then the local player. Speaker-aware code lives here in the app
/// target, behind the same flag karaoke uses; the package only ever sees a `PlaybackSample`.
///
/// Reads only. Never adds hooks to `PlayerManager`, `BookPlayerModel` or `AudioPlayer`.
enum SnipPositionSource {
  @MainActor
  static func sample() -> PlaybackSample? {
    #if SPEAKER_STACK
    if let session = SpeakerSessionManager.shared.current, session.hasOwnSession,
      SpeakerSessionManager.shared.activeSession(for: session.itemID) != nil
    {
      return PlaybackSample(
        itemID: session.itemID,
        position: session.currentPosition,
        isPlaying: session.isPlaying,
        speed: 1,
        output: .speaker
      )
    }
    #endif
    guard let current = PlayerManager.shared.current, current.podcastID == nil else { return nil }
    let position =
      current.preciseCurrentTime
      ?? (try? MediaProgress.fetch(bookID: current.id))?.currentTime
      ?? 0
    return PlaybackSample(
      itemID: current.id,
      position: position,
      isPlaying: current.isPlaying,
      speed: current.speed.value,
      output: .local
    )
  }

  /// Title and author for a snip's `source`, from the loaded player when it is that book.
  @MainActor
  static func source(for itemID: String) -> Snip.Source {
    if let current = PlayerManager.shared.current, current.id == itemID {
      return Snip.Source(title: current.title, author: current.author)
    }
    if let local = try? LocalBook.fetch(bookID: itemID) {
      return Snip.Source(title: local.title, author: local.authorNames)
    }
    #if SPEAKER_STACK
    // A book adopted from the speaker (started from Home Assistant) may exist nowhere on the
    // phone; the daemon's state carries its title.
    if let session = SpeakerSessionManager.shared.current, session.itemID == itemID,
      let title = session.remote?.title, !title.isEmpty
    {
      return Snip.Source(title: title, author: nil)
    }
    #endif
    return Snip.Source(title: "", author: nil)
  }
}
