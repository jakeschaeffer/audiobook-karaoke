import API
import Models
import SwiftUI

/// The transcript and "Play on Speaker" experiences, lifted out of the full player so they can be
/// opened straight from a book's menu — before playback has started.
///
/// `KaraokeSheet` and `SpeakerSessionModel` already have no dependency on `BookPlayer.Model`; the
/// player just happens to be the only thing that built them. This mirrors that wiring
/// (`BookPlayer.swift`), with one difference that matters off the player: a menu-launched sheet may
/// target a book that is *not* the current player item, so a seek can't assume a live playhead —
/// see `seek(bookID:to:duration:)`.
enum BookPlaybackSheet: Int, Identifiable {
  case transcript
  case speaker

  var id: Int { rawValue }

  @MainActor @ViewBuilder
  func view(info: BookPlaybackInfo) -> some View {
    // `getOrCreate` hands back the same `MediaProgress` the player mutates while it plays, so reading
    // `.currentTime` on each call tracks a live playhead when this book happens to be playing and
    // returns the saved position when it isn't — the reason no branch is needed here.
    let progress = try? MediaProgress.getOrCreate(for: info.bookID, duration: info.duration)

    switch self {
    case .transcript:
      #if SPEAKER_STACK
      // Same unified surface as the player's transcript entry: the speaker session rides along
      // (never auto-starting) so the output bar can hand playback to either destination.
      let speaker = SpeakerSessionManager.shared.session(
        for: info.bookID,
        startPosition: progress?.currentTime ?? 0,
        autoStart: false,
        onContinueOnPhone: { [info] in
          Self.seek(bookID: info.bookID, to: $0, duration: info.duration)
        }
      )
      KaraokeSheet(
        model: KaraokeSheet.Model(
          itemID: info.bookID,
          duration: info.duration,
          chapters: info.chapters,
          bookContext: info.context,
          positionProvider: { [id = info.bookID] in
            SpeakerSessionManager.shared.livePosition(for: id)
              ?? PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
          },
          onSeek: { [info] time in
            if let speaker = SpeakerSessionManager.shared.activeSession(for: info.bookID) {
              speaker.seek(to: time)
            } else {
              Self.seek(bookID: info.bookID, to: time, duration: info.duration)
            }
          }
        ),
        speaker: speaker
      )
      #else
      KaraokeSheet(
        model: KaraokeSheet.Model(
          itemID: info.bookID,
          duration: info.duration,
          chapters: info.chapters,
          bookContext: info.context,
          positionProvider: { [id = info.bookID] in
            PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
          },
          onSeek: { [info] time in
            Self.seek(bookID: info.bookID, to: time, duration: info.duration)
          }
        )
      )
      #endif

    case .speaker:
      #if SPEAKER_STACK
      let speaker = SpeakerSessionManager.shared.session(
        for: info.bookID,
        startPosition: progress?.currentTime ?? 0,
        autoStart: {
          #if DEBUG
          return !DebugLaunchOptions.speakerIdle
          #else
          return true
          #endif
        }(),
        onContinueOnPhone: { Self.seek(bookID: info.bookID, to: $0, duration: info.duration) }
      )
      KaraokeSheet(
        model: KaraokeSheet.Model(
          itemID: info.bookID,
          duration: info.duration,
          chapters: info.chapters,
          bookContext: info.context,
          positionProvider: { speaker.currentPosition },
          onSeek: { speaker.seek(to: $0) }
        ),
        speaker: speaker
      )
      .onAppear {
        // The speaker owns audio output from here; stop any local playback so the two don't overlap.
        // A no-op when nothing is playing, which is the common pre-playback case.
        PlayerManager.shared.pause()
      }
      #else
      // Unreachable in the store build (its menus never offer the speaker), but the case must
      // still produce a view.
      EmptyView()
      #endif
    }
  }

  /// Move playback to `time`. If this book is already the current player item, seek it live — the same
  /// thing the in-player transcript does. Otherwise a tapped line (or "continue on phone" from the
  /// speaker) means "start this book here": playback resumes from the saved position on load, so
  /// writing the target first is the deterministic way to open at `time` without racing the load.
  @MainActor
  /// Internal (not private) so the snip surfaces can "play from here" on a book that isn't loaded.
  static func seek(bookID: String, to time: TimeInterval, duration: TimeInterval) {
    let manager = PlayerManager.shared
    if manager.current?.id == bookID {
      manager.current?.onSeekToTime(time)
      return
    }
    Task {
      try? MediaProgress.updateProgress(
        for: bookID,
        currentTime: time,
        duration: duration,
        progress: duration > 0 ? min(time / duration, 1) : 0
      )
      await manager.play(bookID)
    }
  }
}

/// The minimum a book needs to hand to `BookPlaybackSheet` — every menu that shows these actions can
/// produce it. `nil`-returning initializers double as the "does this item even have audio?" gate: an
/// ebook-only item (over half this library) can't offer a transcript or a speaker session.
struct BookPlaybackInfo {
  let bookID: String
  let duration: TimeInterval
  let chapters: [KaraokeSheet.Model.ChapterMarker]
  /// Title/author grounding for the LLM cleanup pass.
  let context: String?

  init?(_ book: Book) {
    guard book.mediaType.contains(.audiobook) else { return nil }
    self.bookID = book.id
    self.duration = book.duration
    self.chapters = (book.chapters ?? []).map(KaraokeSheet.Model.ChapterMarker.init)
    let author = book.media.metadata.authors?.first?.name ?? book.authorName
    self.context = author.map { "\(book.title) by \($0)" } ?? book.title
  }

  init?(_ book: LocalBook) {
    guard book.mediaType.contains(.audiobook) else { return nil }
    self.bookID = book.bookID
    self.duration = book.duration
    self.chapters = book.chapters.map(KaraokeSheet.Model.ChapterMarker.init)
    let author = book.authors.first?.name
    self.context = author.map { "\(book.title) by \($0)" } ?? book.title
  }
}

extension KaraokeSheet.Model.ChapterMarker {
  init(_ chapter: Models.Chapter) {
    self.init(id: chapter.id, title: chapter.title, start: chapter.start, end: chapter.end)
  }

  init(_ chapter: Book.Media.Chapter) {
    self.init(id: chapter.id, title: chapter.title, start: chapter.start, end: chapter.end)
  }
}
