import SwiftUI

/// The player's transport row — and the heart of the Spotify-Connect-style mirroring: when a
/// speaker session is live for this book, every control drives the *speaker* (toggle, skips,
/// chapter jumps route through the daemon); otherwise everything is exactly the local path it
/// always was. The routing is view-level by design — `BookPlayerModel`/`AudioPlayer` never learn
/// about the speaker, so local playback reliability is untouched by construction.
struct BookPlayerControls: View {
  @ObservedObject var model: BookPlayer.Model
  @ObservedObject private var preferences = UserPreferences.shared

  #if SPEAKER_STACK
  private var speaker: SpeakerSessionModel? {
    SpeakerSessionManager.shared.activeSession(for: model.id)
  }
  #endif

  var body: some View {
    HStack(spacing: 0) {
      if let chapters = model.chapters, chapters.chapters.count > 1, !preferences.hideChapterSkipButtons {
        Button(action: {
          Haptics.impact(.light)
          #if SPEAKER_STACK
          if let speaker {
            speakerChapterJump(-1, speaker)
            return
          }
          #endif
          chapters.onPreviousChapterTapped()
        }) {
          Image(systemName: "backward.end")
            .font(.system(size: 22, weight: .regular))
            .foregroundColor(previousChapterDisabled ? .white.opacity(0.3) : .white)
        }
        .disabled(previousChapterDisabled)
        .accessibilityLabel("Previous chapter")
      }

      Spacer(minLength: 8)

      Button(action: {
        Haptics.impact(.light)
        #if SPEAKER_STACK
        if let speaker {
          speaker.skip(-preferences.skipBackwardInterval)
          return
        }
        #endif
        model.onSkipBackwardTapped(seconds: preferences.skipBackwardInterval)
      }) {
        Image(
          systemName: "gobackward.\(Int(preferences.skipBackwardInterval))"
        )
        .font(
          .system(
            size: preferences.hideChapterSkipButtons ? 32 : 28,
            weight: .regular
          )
        )
        .minimumScaleFactor(0.5)
        .foregroundColor(transportDimmed ? .white.opacity(0.3) : .white)
      }
      .accessibilityLabel("Skip backward \(Int(preferences.skipBackwardInterval)) seconds")

      Spacer(minLength: 8)

      Button(action: {
        Haptics.impact(.medium)
        #if SPEAKER_STACK
        if let speaker {
          speaker.togglePlayback()
          return
        }
        #endif
        model.onTogglePlaybackTapped()
      }) {
        ZStack {
          if transportDimmed {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .white))
          } else {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 48))
              .foregroundColor(.white)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .frame(width: 80, height: 80)
      .accessibilityLabel(isPlaying ? "Pause" : "Play")

      Spacer(minLength: 8)

      Button(action: {
        Haptics.impact(.light)
        #if SPEAKER_STACK
        if let speaker {
          speaker.skip(preferences.skipForwardInterval)
          return
        }
        #endif
        model.onSkipForwardTapped(seconds: preferences.skipForwardInterval)
      }) {
        Image(systemName: "goforward.\(Int(preferences.skipForwardInterval))")
          .font(
            .system(
              size: preferences.hideChapterSkipButtons ? 32 : 28,
              weight: .regular
            )
          )
          .minimumScaleFactor(0.5)
          .foregroundColor(transportDimmed ? .white.opacity(0.3) : .white)
      }
      .accessibilityLabel("Skip forward \(Int(preferences.skipForwardInterval)) seconds")

      Spacer(minLength: 8)

      if let chapters = model.chapters, chapters.chapters.count > 1, !preferences.hideChapterSkipButtons {
        Button(action: {
          Haptics.impact(.light)
          #if SPEAKER_STACK
          if let speaker {
            speakerChapterJump(1, speaker)
            return
          }
          #endif
          chapters.onNextChapterTapped()
        }) {
          Image(systemName: "forward.end")
            .font(.system(size: 22, weight: .regular))
            .foregroundColor(nextChapterDisabled ? .white.opacity(0.3) : .white)
        }
        .disabled(nextChapterDisabled)
        .accessibilityLabel("Next chapter")
      }
    }
    .buttonStyle(.borderless)
    .opacity(model.isLocked ? 0.4 : 1)
    .padding(.horizontal)
  }

  // MARK: - Speaker-aware state

  /// While the speaker owns playback, local `isLoading` is irrelevant — the phone isn't the one
  /// buffering. Locally, dimming keeps its original meaning.
  private var transportDimmed: Bool {
    #if SPEAKER_STACK
    return speaker == nil && model.isLoading
    #else
    return model.isLoading
    #endif
  }

  private var isPlaying: Bool {
    #if SPEAKER_STACK
    if let speaker { return speaker.isPlaying }
    #endif
    return model.isPlaying
  }

  private var previousChapterDisabled: Bool {
    #if SPEAKER_STACK
    if let speaker {
      // Mirrors local semantics: a tap either restarts the chapter or goes back one, so it's
      // meaningful anywhere but the very start of the first chapter.
      let (index, position) = speakerChapterState(speaker)
      return index == 0 && position < 2
    }
    #endif
    return model.isLoading || model.chapters?.canGoPreviousChapter != true
  }

  private var nextChapterDisabled: Bool {
    #if SPEAKER_STACK
    if let speaker {
      return speakerChapterState(speaker).index >= sortedChapters.count - 1
    }
    #endif
    return model.isLoading || model.chapters?.canGoNextChapter != true
  }

  // MARK: - Speaker chapter jumps

  #if SPEAKER_STACK
  /// Chapter prev/next against the *speaker's* playhead. Pure position math over the chapter
  /// list — the local `ChapterPickerSheetViewModel` tracks the local playhead, which is frozen
  /// during a session, so its index would jump chapters relative to the wrong place.
  private var sortedChapters: [ChapterPickerSheet.Model.Chapter] {
    (model.chapters?.chapters ?? []).sorted { $0.start < $1.start }
  }

  private func speakerChapterState(
    _ speaker: SpeakerSessionModel
  )
    -> (index: Int, position: TimeInterval)
  {
    let chapters = sortedChapters
    guard !chapters.isEmpty else { return (0, 0) }
    let index = chapters.index(for: speaker.currentPosition)
    return (index, speaker.currentPosition - chapters[index].start)
  }

  private func speakerChapterJump(_ direction: Int, _ speaker: SpeakerSessionModel) {
    let chapters = sortedChapters
    guard !chapters.isEmpty else { return }
    let (index, timeInChapter) = speakerChapterState(speaker)

    let target: Int
    if direction < 0 {
      // Same feel as local: early in a chapter goes back one, otherwise restart this chapter.
      target = timeInChapter < 2 && index > 0 ? index - 1 : index
    } else {
      guard index < chapters.count - 1 else { return }
      target = index + 1
    }
    speaker.seek(to: chapters[target].start + 0.1)
  }
  #endif
}
