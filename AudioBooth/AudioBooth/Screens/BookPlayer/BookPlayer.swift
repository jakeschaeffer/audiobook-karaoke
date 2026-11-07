import API
import AVKit
import Combine
import Models
import SwiftData
import SwiftUI
import Transcription

struct BookPlayer: View {
  @ObservedObject var model: Model

  @Environment(\.dismiss) private var dismiss

  @ObservedObject private var playerManager = PlayerManager.shared
  @ObservedObject private var preferences = UserPreferences.shared
  /// The output chooser — what the speaker pill (and the menu's speaker entry, once a session
  /// exists) opens: pick where playback lives, Connect-style, instead of navigating anywhere.
  @State private var speakerChooserPresented = false

  /// The player's existing chapter data, mapped for the transcript sheet — no separate fetch.
  private var karaokeChapters: [KaraokeSheet.Model.ChapterMarker] {
    (model.chapters?.chapters ?? []).map {
      KaraokeSheet.Model.ChapterMarker(id: $0.id, title: $0.title, start: $0.start, end: $0.end)
    }
  }

  /// Title/author grounding for the cleanup model — how "Bagamon" becomes Bagman.
  private var karaokeBookContext: String {
    model.author.map { "\(model.title) by \($0)" } ?? model.title
  }

  private var supportedOrientations: UIInterfaceOrientationMask {
    switch preferences.playerOrientation {
    case .auto:
      return .all
    case .portrait:
      return .portrait
    case .landscape:
      return .landscape
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        playerBackground
          .accessibilityHidden(true)
          .ignoresSafeArea()

        GeometryReader { proxy in
          Group {
            if proxy.size.width > proxy.size.height {
              landscapeLayout(artworkWidth: proxy.leadingPanelWidth.map { $0 - 24 })
            } else {
              portraitLayout(artworkHeight: proxy.topPanelHeight)
            }
          }
          .frame(width: proxy.size.width, height: proxy.size.height)
        }

        if model.isLocked {
          unlockOverlay
        }

        if let message = model.positionSyncMessage, !model.isLocked {
          VStack {
            PositionSyncBanner(
              message: message,
              onCatchUp: model.onPositionSyncOfferAccepted,
              onDismiss: model.onPositionSyncDismissed
            )

            Spacer()
          }
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.easeInOut, value: model.isLocked)
      .animation(.easeInOut, value: model.positionSyncMessage)
      .orientationLock(supportedOrientations)
      .onAppear {
        // Through the coordinator: a running transcription/cleanup holds the screen independently
        // of this preference, and neither side may stomp the other (see ScreenWakeCoordinator).
        ScreenWakeCoordinator.shared.setBaseKeepAwake(preferences.keepScreenAwakeInPlayer)
        model.onAppear()
        #if SPEAKER_STACK
        // The speaker may already be mid-book via Home Assistant; adopt that session so the
        // pill and karaoke cover are live the moment the player opens.
        SpeakerSessionManager.shared.discoverExistingSession()
        #endif
        #if DEBUG
        if DebugLaunchOptions.autoOpenTranscript, model.podcastID == nil {
          model.isKaraokePresented = true
        }
        #if SPEAKER_STACK
        if DebugLaunchOptions.autoOpenSpeaker, model.podcastID == nil {
          model.isSpeakerPresented = true
        }
        #endif
        if DebugLaunchOptions.autoOpenHistory {
          // model.history is built asynchronously during player setup, and the base model's vars
          // aren't @Published — a menu tap gets its re-render from the menu dismissing, so a
          // programmatic open must retry until the model exists and then poke objectWillChange.
          // Single delayed tap: firing synchronously in onAppear sets isPresented before the sheet
          // modifier has ever rendered false, so SwiftUI never sees a false→true edge. The model's
          // vars aren't @Published, so the render that notices the edge needs an explicit poke.
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            model.onHistoryTapped()
            model.objectWillChange.send()
          }
        }
        #endif
      }
      .onDisappear { ScreenWakeCoordinator.shared.setBaseKeepAwake(false) }
      .onChange(of: preferences.keepScreenAwakeInPlayer) { _, newValue in
        ScreenWakeCoordinator.shared.setBaseKeepAwake(newValue)
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(
            "Minify",
            systemImage: "chevron.down",
            action: {
              playerManager.hideFullPlayer()
              dismiss()
            }
          )
          .tint(.primary)
        }

        if #available(iOS 27.1, *) {
          airPlayToolbarItem
            .axisBehavior(.verticalPreferred)
        } else {
          airPlayToolbarItem
        }

        if #available(iOS 26.0, *) {
          ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            if let podcastID = model.podcastID {
              NavigationLink(value: NavigationDestination.podcast(id: podcastID)) {
                Label("Podcast Details", systemImage: "mic")
              }
            } else {
              NavigationLink(value: NavigationDestination.book(id: model.id)) {
                Label("Book Details", systemImage: "book")
              }
            }

            if model.podcastID == nil {
              Button(action: { model.isKaraokePresented = true }) {
                Label("Transcript", systemImage: "text.bubble")
              }
              #if SPEAKER_STACK
              if let session = SpeakerSessionManager.shared.speakerSession(for: model.id) {
                // A session already exists: this entry is the same output chooser as the pill —
                // never a blind re-seek of a session that's mid-book (or deliberately paused).
                Button(action: { speakerChooserPresented = true }) {
                  Label(
                    session.isPlaying ? "Playing on Speaker…" : "Paused on Speaker…",
                    systemImage: "hifispeaker"
                  )
                }
              } else if CompanionStore.shared.supportsSpeaker {
                Button(action: { playOnSpeaker() }) {
                  Label("Play on Speaker", systemImage: "hifispeaker")
                }
              }
              #endif
            }

            if Audiobookshelf.shared.authentication.server?.permissions?.download == true,
              model.downloadState == .notDownloaded
            {
              Button(action: { model.onDownloadTapped() }) {
                Label("Download", systemImage: "icloud.and.arrow.down")
              }
            }

            let disabledControls = Set(PlayerControl.allCases).subtracting(preferences.playerControls)
            if disabledControls.contains(.speed) {
              Button(action: { model.speed.isPresented = true }) {
                Label(PlayerControl.speed.displayName, systemImage: PlayerControl.speed.systemImage)
              }
            }
            if disabledControls.contains(.timer) {
              Button(action: { model.timer.isPresented = true }) {
                Label(PlayerControl.timer.displayName, systemImage: PlayerControl.timer.systemImage)
              }
            }
            // Snips replace ABS bookmarks in this fork: the list is always a menu entry, the capture
            // button too when it isn't in the bar.
            if model.podcastID == nil {
              SnipMenuItems(itemID: model.id, includeCapture: disabledControls.contains(.snip))
            }
            // Always in the menu (not only when removed from the main controls): the sessions view
            // is this fork's "where was I on Tuesday" surface.
            if model.history != nil {
              Button(action: { model.onHistoryTapped() }) {
                Label(PlayerControl.history.displayName, systemImage: PlayerControl.history.systemImage)
              }
            }
            if disabledControls.contains(.volume) {
              Button(action: { model.volume.isPresented = true }) {
                Label(PlayerControl.volume.displayName, systemImage: PlayerControl.volume.systemImage)
              }
            }

            if disabledControls.contains(.equalizer) {
              Button(action: { model.equalizer.isPresented = true }) {
                Label(PlayerControl.equalizer.displayName, systemImage: PlayerControl.equalizer.systemImage)
              }
            }

            if model.isLocked {
              Button(action: { model.onUnlockTapped() }) {
                Label("Unlock", systemImage: "lock.open.fill")
              }
            } else if disabledControls.contains(.lock) {
              Button(action: { model.onLockTapped() }) {
                Label(PlayerControl.lock.displayName, systemImage: PlayerControl.lock.systemImage)
              }
            }

            Button(action: { model.isQueuePresented = true }) {
              Label("Queue", systemImage: "list.bullet")
            }

            if model.supportsPageMatch, disabledControls.contains(.pageMatch) {
              Button(action: { model.onPageMatchTapped() }) {
                Label(PlayerControl.pageMatch.displayName, systemImage: PlayerControl.pageMatch.systemImage)
              }
            }

            Divider()

            Button(action: { model.isSettingsPresented = true }) {
              Label("Player Settings", systemImage: "gearshape")
            }
          } label: {
            Label("More", systemImage: "ellipsis")
          }
          .tint(.primary)
        }
      }
      .navigationDestinations()
    }
    .preferredColorScheme(.dark)
    .snipSurfaces(itemID: model.id)
    .sheet(
      isPresented: Binding(
        get: { model.chapters?.isPresented ?? false },
        set: { newValue in model.chapters?.isPresented = newValue }
      )
    ) {
      if let chapters = model.chapters {
        ChapterPickerSheet(model: chapters)
      }
    }
    .adaptiveSheet(isPresented: $model.volume.isPresented) {
      FloatPickerSheet(model: $model.volume)
    }
    .adaptiveSheet(isPresented: $model.equalizer.isPresented) {
      EqualizerSheet(model: model.equalizer)
    }
    .adaptiveSheet(isPresented: $model.speed.isPresented) {
      FloatPickerSheet(model: $model.speed)
    }
    .adaptiveSheet(isPresented: $model.timer.isPresented) {
      TimerPickerSheet(model: $model.timer)
    }
    .sheet(item: $model.timer.completedAlert) { model in
      TimerCompletedAlertView(model: model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.bookmarks?.isPresented ?? false },
        set: { newValue in model.bookmarks?.isPresented = newValue }
      )
    ) {
      if let bookmarks = model.bookmarks {
        BookmarkViewerSheet(model: bookmarks)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.history?.isPresented ?? false },
        set: { newValue in model.history?.isPresented = newValue }
      )
    ) {
      if let history = model.history {
        PlaybackHistorySheet(model: history)
      }
    }
    .sheet(isPresented: $model.isQueuePresented) {
      PlayerQueueView(model: PlayerQueueViewModel())
    }
    .sheet(isPresented: $model.isKaraokePresented) {
      let progress = try? MediaProgress.getOrCreate(
        for: model.id,
        duration: model.playbackProgress.total
      )
      #if SPEAKER_STACK
      // The transcript entry gets a speaker session too (never auto-starting), so the sheet is
      // one surface with an output choice — play here or on the speaker — not two separate modes.
      let speaker = SpeakerSessionManager.shared.session(
        for: model.id,
        startPosition: progress?.currentTime ?? 0,
        autoStart: false,
        onContinueOnPhone: { position in
          model.onSeekToTime(position)
          model.onPlayTapped()
        }
      )
      KaraokeSheet(
        model: KaraokeSheet.Model(
          itemID: model.id,
          duration: model.playbackProgress.total,
          chapters: karaokeChapters,
          bookContext: karaokeBookContext,
          // When a speaker session is live for this book, the transcript follows the speaker;
          // otherwise local progress. Checked per tick, so it switches over live.
          positionProvider: { [id = model.id] in
            SpeakerSessionManager.shared.livePosition(for: id)
              ?? PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
          },
          onSeek: { [id = model.id] time in
            if let speaker = SpeakerSessionManager.shared.activeSession(for: id) {
              speaker.seek(to: time)
            } else {
              model.onSeekToTime(time)
            }
          }
        ),
        speaker: speaker
      )
      #else
      KaraokeSheet(
        model: KaraokeSheet.Model(
          itemID: model.id,
          duration: model.playbackProgress.total,
          chapters: karaokeChapters,
          bookContext: karaokeBookContext,
          positionProvider: { [id = model.id] in
            PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
          },
          onSeek: { model.onSeekToTime($0) }
        )
      )
      #endif
    }
    #if SPEAKER_STACK
    // Reached only by the DEBUG `-autoOpenSpeaker` launch arg these days: the pill and the menu
    // both open the output chooser instead of navigating here, and the transcript surface itself
    // mirrors the speaker once it's the active output. Kept because scripted runs use it.
    .sheet(isPresented: $model.isSpeakerPresented) {
      let progress = try? MediaProgress.getOrCreate(
        for: model.id,
        duration: model.playbackProgress.total
      )
      // Through the manager: when the speaker is already playing this book, this returns the live
      // session — no re-seed from local progress, no rewind — and the sheet just rejoins it.
      let speaker = SpeakerSessionManager.shared.session(
        for: model.id,
        startPosition: progress?.currentTime ?? 0,
        autoStart: {
          #if DEBUG
          return !DebugLaunchOptions.speakerIdle
          #else
          return true
          #endif
        }(),
        onContinueOnPhone: { position in
          model.onSeekToTime(position)
          model.onPlayTapped()
        }
      )
      KaraokeSheet(
        model: KaraokeSheet.Model(
          itemID: model.id,
          duration: model.playbackProgress.total,
          chapters: karaokeChapters,
          bookContext: karaokeBookContext,
          positionProvider: { speaker.currentPosition },
          onSeek: { speaker.seek(to: $0) }
        ),
        speaker: speaker
      )
    }
    #endif
    .sheet(item: $model.pageMatch) { pageMatch in
      PageMatchSheet(model: pageMatch)
    }
    .sheet(item: $model.positionSync) { positionSync in
      PositionSyncSheet(model: positionSync)
    }
    .sheet(isPresented: $model.isSettingsPresented) {
      NavigationStack {
        PlayerPreferencesView()
          .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
              Button("Close", systemImage: "xmark", action: { model.isSettingsPresented = false })
                .tint(.primary)
            }
          }
      }
    }
    #if SPEAKER_STACK
    .confirmationDialog(
      speakerChooserTitle,
      isPresented: $speakerChooserPresented,
      titleVisibility: .visible
    ) {
      if let session = SpeakerSessionManager.shared.speakerSession(for: model.id) {
        if model.isPlaying {
          // The phone is the live output, so the speaker option is a *transfer*: pause here,
          // pick up there at this exact position (a seek plays, even from paused). Resuming
          // the speaker's own stale position would double-audio over the phone — and offering
          // "Continue on iPhone" is meaningless when the iPhone is already where playback is.
          Button("Play on Speaker") {
            transferToSpeaker(session)
          }
        } else {
          Button("Continue on iPhone") {
            // Routed through the session so the pause-first contract holds (no double audio);
            // the session's handoff callback seeks and resumes the local player.
            session.continueOnPhone()
          }
          if !session.isPlaying {
            Button("Resume on Speaker") {
              session.togglePlayback()
            }
          }
        }
        Button("Stop Speaker", role: .destructive) {
          session.stopSpeaker()
        }
      }
    }
    #endif
  }

  #if SPEAKER_STACK
  private var speakerChooserTitle: String {
    let session = SpeakerSessionManager.shared.speakerSession(for: model.id)
    return session?.isPlaying == true
      ? String(localized: "Playing on Speaker")
      : String(localized: "Paused on Speaker")
  }

  /// Transfer live local playback to an existing speaker session: pause here, play there from
  /// this position. The daemon's seek-plays semantics make one seek do it, paused or not.
  private func transferToSpeaker(_ session: SpeakerSessionModel) {
    let position =
      (try? MediaProgress.getOrCreate(for: model.id, duration: model.playbackProgress.total))?
      .currentTime ?? 0
    model.onPauseTapped()
    session.seek(to: position)
  }

  /// Spotify-style output switch, straight from the menu: no navigation, no sheet. Pause the
  /// phone, and the speaker picks up from this exact position — the pill and the mirrored
  /// transport are the controls from there. `seek` on an idle session *is* play-at-position
  /// (and on a foreign one it replaces, same as the transcript's handoff button).
  private func playOnSpeaker() {
    let position =
      (try? MediaProgress.getOrCreate(for: model.id, duration: model.playbackProgress.total))?
      .currentTime ?? 0
    model.onPauseTapped()
    let session = SpeakerSessionManager.shared.session(
      for: model.id,
      startPosition: position,
      autoStart: false,
      onContinueOnPhone: { position in
        model.onSeekToTime(position)
        model.onPlayTapped()
      }
    )
    Task {
      await session.activate()
      session.seek(to: position)
    }
  }
  #endif

  private var airPlayToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      HStack(spacing: 0) {
        AirPlayButton()
          .frame(width: 36, height: 36)
          .tint(.primary)
      }
    }
  }

  @ViewBuilder
  private var playerBackground: some View {
    switch preferences.playerBackgroundStyle {
    case .gradient:
      if #available(iOS 18.0, *) {
        meshBackground
      } else {
        solidBackground
      }
    case .solid:
      solidBackground
    case .off:
      Color(white: 0.1)
    }
  }

  private var solidBackground: some View {
    model.backgroundColor
      .overlay {
        LinearGradient(
          colors: [.clear, .black.opacity(0.3)],
          startPoint: .top,
          endPoint: .bottom
        )
      }
  }

  @available(iOS 18.0, *)
  private var meshBackground: some View {
    let color = model.backgroundColor
    let secondary = model.secondaryBackgroundColor
    let middle = color.mix(with: secondary, by: 0.5)
    return MeshGradient(
      width: 3,
      height: 3,
      points: [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
      ],
      colors: [
        color, middle, secondary,
        color.mix(with: .black, by: 0.15),
        color.mix(with: secondary, by: 0.6).mix(with: .black, by: 0.2),
        secondary.mix(with: .black, by: 0.3),
        color.mix(with: .black, by: 0.55),
        color.mix(with: .black, by: 0.6),
        middle.mix(with: .black, by: 0.55),
      ]
    )
  }

  private func portraitLayout(artworkHeight: CGFloat?) -> some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        Artwork(model: model)
          .frame(height: artworkHeight)

        Spacer(minLength: 24)

        VStack(spacing: 32) {
          VStack(spacing: 12) {
            speakerIndicator
            chaptersDisplay
          }
          BookPlayerPlaybackSection(model: model)
        }
        .frame(maxWidth: 800)

        Spacer(minLength: 24)

        bottomControlBar
      }
      .padding(.horizontal, 24)
      .disabled(model.isLoading)
      .allowsHitTesting(!model.isLocked)
    }
  }

  private func landscapeLayout(artworkWidth: CGFloat?) -> some View {
    HStack(spacing: 24) {
      Artwork(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .containerRelativeFrame(.horizontal) { width, _ in artworkWidth ?? width * 0.4 }

      VStack(spacing: 24) {
        Spacer()

        VStack(spacing: 12) {
          speakerIndicator
          chaptersDisplay
        }

        BookPlayerPlaybackSection(model: model)

        bottomControlBar

        Spacer()
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .disabled(model.isLoading)
      .allowsHitTesting(!model.isLocked)
    }
    .padding(.horizontal, 24)
  }

  /// The device chip, Connect-style: shown while the speaker holds a session for this book at all
  /// (the loose predicate — a paused speaker is still a destination worth one glance), it names
  /// the speaker's state and opens the output chooser. Choosing playback surfaces is the chooser's
  /// job; the pill itself never navigates and never touches playback.
  @ViewBuilder
  private var speakerIndicator: some View {
    #if SPEAKER_STACK
    if let speaker = SpeakerSessionManager.shared.speakerSession(for: model.id) {
      Button {
        Haptics.impact(.soft)
        speakerChooserPresented = true
      } label: {
        Label(
          speaker.isPlaying ? "Playing on Speaker" : "Paused on Speaker",
          systemImage: "hifispeaker.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.white.opacity(0.15), in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Chooses where playback continues")
    }
    #endif
  }

  /// The chapter under the *active* playhead: the speaker's when a session is live, else the
  /// local model's own tracking. Without this, the title row said "Chapter 1" while the scrubber
  /// above it showed the speaker eight hours in.
  private var displayedChapter: ChapterPickerSheet.Model.Chapter? {
    guard let chapters = model.chapters else { return nil }
    #if SPEAKER_STACK
    if let speaker = SpeakerSessionManager.shared.activeSession(for: model.id),
      !chapters.chapters.isEmpty
    {
      let sorted = chapters.chapters.sorted { $0.start < $1.start }
      return sorted[sorted.index(for: speaker.currentPosition)]
    }
    #endif
    return chapters.current
  }

  @ViewBuilder
  private var chaptersDisplay: some View {
    if let chapters = model.chapters, let chapter = displayedChapter {
      Button(action: {
        Haptics.impact(.soft)
        chapters.isPresented = true
      }) {
        Marquee {
          HStack {
            Image(systemName: "list.bullet")
              .foregroundColor(.white.opacity(0.7))
            Text(chapter.title)
              .foregroundColor(.white)
              .font(.headline)
          }
        }
        .id(chapter.title)
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8)
    } else {
      Marquee {
        Text(model.title)
          .foregroundColor(.white)
          .font(.headline)
      }
      .id(model.title)
    }
  }

  private var bottomControlBar: some View {
    HStack(alignment: .bottom, spacing: 0) {
      ForEach(preferences.playerControls) { control in
        controlButton(for: control)
      }
    }
    .foregroundColor(.white.opacity(0.7))
    .padding(.vertical, 12)
    .buttonStyle(.borderless)
    .opacity(model.isLocked ? 0 : 1)
  }

  private var unlockOverlay: some View {
    VStack {
      Spacer()

      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
        Text("Hold to unlock")
      }
      .font(.footnote)
      .fontWeight(.bold)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(Color.black.opacity(0.7))
      .foregroundColor(.white)
      .clipShape(.capsule)
      .contentShape(.capsule)
      .onLongPressGesture(minimumDuration: 1) {
        Haptics.impact(.medium)
        model.onUnlockTapped()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("Player locked")
      .accessibilityHint("Touch and hold to unlock")
      .accessibilityAction { model.onUnlockTapped() }
    }
    .padding(.bottom, 24)
    .transition(.opacity)
  }

  @ViewBuilder
  private func controlButton(for control: PlayerControl) -> some View {
    switch control {
    case .speed:
      Button(action: {
        Haptics.impact(.soft)
        model.speed.isPresented = true
      }) {
        VStack(spacing: 6) {
          Text(verbatim: "\(model.speed.value.formatted(.number.precision(.fractionLength(0...2))))×")
            .font(.system(size: 16, weight: .medium))
            .frame(height: 20)
          Text(control.displayName)
            .font(.caption2)
        }
      }
      .frame(maxWidth: .infinity)

    case .timer:
      let isActive: Bool = {
        if case .none = model.timer.current { return false }
        return true
      }()
      Button(action: {
        Haptics.impact(.soft)
        model.timer.isPresented = true
      }) {
        VStack(spacing: 6) {
          Image(systemName: control.systemImage)
            .font(.system(size: 20))
            .frame(width: 20, height: 20)
          Text(control.displayName)
            .font(.caption2)
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.white.opacity(0.7))
      }
      .frame(maxWidth: .infinity)

    case .bookmarks:
      // Replaced by snips (below). The case stays so saved layouts that name it still decode.
      EmptyView()

    case .snip:
      if model.podcastID == nil {
        SnipControlButton()
      }

    case .transcript:
      // Transcripts are books-only, same gate as the menu item; podcasts just don't render it.
      if model.podcastID == nil {
        Button(action: {
          Haptics.impact(.soft)
          model.isKaraokePresented = true
        }) {
          VStack(spacing: 6) {
            Image(systemName: control.systemImage)
              .font(.system(size: 20))
              .frame(width: 20, height: 20)
            Text(control.displayName)
              .font(.caption2)
          }
        }
        .frame(maxWidth: .infinity)
      }

    case .history:
      if model.history != nil {
        Button(action: {
          Haptics.impact(.soft)
          model.onHistoryTapped()
        }) {
          VStack(spacing: 6) {
            Image(systemName: control.systemImage)
              .font(.system(size: 20))
              .frame(width: 20, height: 20)
            Text(control.displayName)
              .font(.caption2)
          }
        }
        .frame(maxWidth: .infinity)
      }

    case .volume:
      Button(action: {
        Haptics.impact(.soft)
        model.volume.isPresented = true
      }) {
        VStack(spacing: 6) {
          Image(systemName: control.systemImage)
            .font(.system(size: 20))
            .frame(width: 20, height: 20)
          Text(control.displayName)
            .font(.caption2)
        }
      }
      .frame(maxWidth: .infinity)

    case .equalizer:
      Button(action: {
        Haptics.impact(.soft)
        model.equalizer.isPresented = true
      }) {
        VStack(spacing: 6) {
          Image(systemName: control.systemImage)
            .font(.system(size: 20))
            .frame(width: 20, height: 20)
          Text(control.displayName)
            .font(.caption2)
        }
      }
      .frame(maxWidth: .infinity)

    case .lock:
      Button(action: {
        Haptics.impact(.soft)
        model.onLockTapped()
      }) {
        VStack(spacing: 6) {
          Image(systemName: control.systemImage)
            .font(.system(size: 20))
            .frame(width: 20, height: 20)
          Text(control.displayName)
            .font(.caption2)
        }
      }
      .frame(maxWidth: .infinity)

    case .pageMatch:
      if model.supportsPageMatch {
        Button(action: {
          Haptics.impact(.soft)
          model.onPageMatchTapped()
        }) {
          VStack(spacing: 6) {
            Image(systemName: control.systemImage)
              .font(.system(size: 20))
              .frame(width: 20, height: 20)
            Text(control.displayName)
              .font(.caption2)
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}

extension BookPlayer {
  struct Artwork: View {
    @ObservedObject var model: Model
    @ObservedObject private var preferences = UserPreferences.shared

    var body: some View {
      if preferences.playerKaraokeCover, model.podcastID == nil {
        // Karaoke mode: the transcript takes the cover's place (same square, same styling).
        // Books only — podcasts hide transcript surfaces everywhere else too.
        KaraokeCoverView(model: model)
      } else {
        cover
      }
    }

    private var cover: some View {
      NavigationLink(
        value: model.podcastID != nil
          ? NavigationDestination.podcast(id: model.podcastID ?? model.id)
          : NavigationDestination.book(id: model.id)
      ) {
        Cover(url: model.coverURL, style: .plain)
          .frame(minWidth: 200, maxWidth: 600, minHeight: 200, maxHeight: 600)
          .aspectRatio(1, contentMode: .fit)
          .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
      }
      .accessibilityLabel("Book details")
      .contextMenu {
        if model.podcastID == nil {
          Button {
            withAnimation { preferences.playerKaraokeCover = true }
          } label: {
            Label("Karaoke Mode", systemImage: "quote.bubble")
          }
        }
      }
      .overlay(alignment: .topLeading) {
        let progress = model.playbackProgress.totalProgress.formatted(.percent.precision(.fractionLength(0)))
        badge(text: Text(progress), accessibilityLabel: progress)
      }
      .overlay(alignment: .topTrailing) {
        VStack(alignment: .trailing, spacing: 6) {
          timerOverlay
          alarmOverlay
        }
      }
      .buttonStyle(.plain)
    }

    @ViewBuilder
    private var timerOverlay: some View {
      switch model.timer.current {
      case .preset(let seconds), .custom(let seconds):
        let text = Duration.seconds(seconds).formatted(
          .units(
            allowed: [.hours, .minutes, .seconds],
            width: .narrow
          )
        )
        let remaining = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds]))
        let accessibilityLabel = "Sleep timer: \(remaining) remaining"
        badge(icon: "timer", text: Text(text), accessibilityLabel: accessibilityLabel)
      case .chapters(let count):
        let label = count > 1 ? "End of \(count) chapters" : "End of chapter"
        let accessibilityLabel = "Sleep timer: \(label)"
        badge(icon: "timer", text: Text(label), accessibilityLabel: accessibilityLabel)
      case .atTime, .duration, .none:
        EmptyView()
      }
    }

    @ViewBuilder
    private var alarmOverlay: some View {
      if case .atTime(let trigger) = model.timer.current {
        badge(
          icon: "bell.fill",
          text: Text(
            timerInterval: min(Date(), trigger)...trigger,
            pauseTime: nil,
            countsDown: true,
            showsHours: true
          ),
          accessibilityLabel: "Alarm set"
        )
      }
    }

    @ViewBuilder
    private func badge(icon: String? = nil, text: Text, accessibilityLabel: String) -> some View {
      HStack(spacing: 4) {
        if let icon {
          Image(systemName: icon)
        }
        text
      }
      .font(.footnote)
      .fontWeight(.bold)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.black.opacity(0.7))
      .foregroundColor(.white)
      .clipShape(.capsule)
      .padding(4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
    }
  }
}

extension BookPlayer {
  @Observable
  class Model: ObservableObject {
    let id: String
    let podcastID: String?

    let title: String
    let author: String?
    let coverURL: URL?

    var isPlaying: Bool
    var isLoading: Bool
    var speed: FloatPickerSheet.Model
    var timer: TimerPickerSheet.Model
    var volume: FloatPickerSheet.Model
    var chapters: ChapterPickerSheet.Model?
    var bookmarks: BookmarkViewerSheet.Model?
    var history: PlaybackHistorySheet.Model?
    var equalizer: EqualizerSheet.Model
    var playbackProgress: PlaybackProgressView.Model

    var downloadState: DownloadManager.DownloadState
    var backgroundColor: Color = .black
    var secondaryBackgroundColor: Color = .black
    var progressTint: Color?

    var isPresented: Bool = true
    var isSettingsPresented: Bool = false
    var isQueuePresented: Bool = false
    var isKaraokePresented: Bool = false
    var isSpeakerPresented: Bool = false

    /// Book-absolute seek target. Overridden by the concrete model; the transcript view needs it to
    /// turn a tapped line into a seek.
    func onSeekToTime(_ time: TimeInterval) {}

    /// Book-absolute playhead from the audio clock itself, for the transcript's word highlight —
    /// `MediaProgress.currentTime` only moves in 0.5s steps. Nil when nothing is loaded.
    var preciseCurrentTime: TimeInterval? { nil }
    var isLocked: Bool = false
    var supportsPageMatch: Bool = false
    var pageMatch: PageMatchSheet.Model?
    var positionSyncMessage: LocalizedStringResource?
    var positionSync: PositionSyncSheet.Model?

    var secondsFromStartOfBook: TimeInterval { 0 }

    func onLockTapped() { isLocked = true }
    func onUnlockTapped() { isLocked = false }

    func onAppear() {}
    func onTogglePlaybackTapped() {}
    func onPauseTapped() {}
    func onPlayTapped() {}
    func onSkipForwardTapped(seconds: Double) {}
    func onSkipBackwardTapped(seconds: Double) {}
    func onDownloadTapped() {}
    func onBookmarksTapped() {}
    func onHistoryTapped() {}
    func onPageMatchTapped() {}
    func onPositionSyncTapped() {}
    func onPositionSyncOfferAccepted() {}
    func onPositionSyncDismissed(_ scope: PositionSyncOffer.Dismissal) {}

    init(
      id: String = UUID().uuidString,
      podcastID: String? = nil,
      title: String,
      author: String?,
      coverURL: URL?,
      isPlaying: Bool = false,
      isLoading: Bool = false,
      speed: FloatPickerSheet.Model,
      timer: TimerPickerSheet.Model,
      volume: FloatPickerSheet.Model = .init(),
      chapters: ChapterPickerSheet.Model? = nil,
      bookmarks: BookmarkViewerSheet.Model? = nil,
      history: PlaybackHistorySheet.Model? = nil,
      equalizer: EqualizerSheet.Model = .init(),
      playbackProgress: PlaybackProgressView.Model,
      downloadState: DownloadManager.DownloadState = .notDownloaded
    ) {
      self.id = id
      self.podcastID = podcastID
      self.title = title
      self.author = author
      self.coverURL = coverURL
      self.isPlaying = isPlaying
      self.isLoading = isLoading
      self.speed = speed
      self.timer = timer
      self.volume = volume
      self.chapters = chapters
      self.bookmarks = bookmarks
      self.history = history
      self.equalizer = equalizer
      self.playbackProgress = playbackProgress
      self.downloadState = downloadState
    }
  }
}

extension BookPlayer.Model {
  static var mock: BookPlayer.Model {
    let model = BookPlayer.Model(
      title: "Sample Audiobook",
      author: "Sample Author",
      coverURL: URL(string: "https://m.media-amazon.com/images/I/51YHc7SK5HL._SL500_.jpg"),
      speed: .mock,
      timer: .mock,
      chapters: .mock,
      playbackProgress: .mock
    )
    return model
  }
}

struct AirPlayButton: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let routePickerView = AVRoutePickerView()
    routePickerView.backgroundColor = UIColor.clear
    routePickerView.tintColor = UIColor.white
    return routePickerView
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
  BookPlayer(model: .mock)
}
