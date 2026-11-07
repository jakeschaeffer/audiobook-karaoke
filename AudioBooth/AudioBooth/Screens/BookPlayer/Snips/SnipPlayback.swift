import Foundation
import Models
import Snips

/// "Play from here" for a snip: the loaded player when it is that book, otherwise the same route the
/// Book Details transcript uses to load a book at a position.
enum SnipPlayback {
  @MainActor
  static func play(_ snip: Snip) {
    let time = TimeInterval(snip.startMs) / 1000
    if let current = PlayerManager.shared.current, current.id == snip.itemID {
      current.onSeekToTime(time)
      if !current.isPlaying { current.onPlayTapped() }
      return
    }
    let duration = (try? MediaProgress.fetch(bookID: snip.itemID))?.duration ?? 0
    BookPlaybackSheet.seek(bookID: snip.itemID, to: time, duration: duration)
  }
}
