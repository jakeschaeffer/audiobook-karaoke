import Models
import SwiftUI
import Transcription

/// Position-synced transcript with word-level highlighting.
///
/// The sync logic is ported from abs-session's `/player` page rather than re-derived: find the active
/// segment by binary search for the last one starting at or before the playhead, light words within it
/// whose start has passed, dim everything already read, and keep the active line centred unless the
/// user has scrolled away. When no transcript exists, the sheet is the surface for requesting one from
/// the host worker and watching its progress.
struct KaraokeSheet: View {
  @State var model: Model
  #if SPEAKER_STACK
  /// Present when this sheet is the surface for WiiM playback: the playhead then comes from the
  /// daemon's ticks and a transport bar docks below the transcript. Nil for local playback.
  @State var speaker: SpeakerSessionModel? = nil
  #endif
  @State private var showChapterPicker = false
  /// Teleprompter state: the offset that centres the active row, which row it was computed for,
  /// and whether the current unfollow came from a finger (so the follow-exit hook doesn't
  /// re-position what the touch handoff already positioned).
  @State private var conveyorOffset: CGFloat = 0
  @State private var conveyorActiveID: String?
  @State private var panHandoff = false
  /// Conveyor displacement a finger inherited mid-glide; folded into the scroll view at rest.
  @State private var residualOffset: CGFloat = 0
  /// Bumped when the conveyor has settled — the handoff modifier then parks it (see
  /// `TouchHandoff`).
  @State private var parkRequest = 0
  /// Measured resting position of the content origin in viewport space (see the calibration
  /// overlay); folded into every conveyor offset so coordinate-space guesses never drift it.
  @State private var contentBase: CGFloat = 0
  /// End of the in-flight line-change glide; calibration and corrections wait it out.
  @State private var glideUntil = Date.distantPast
  /// The latest conveyor inputs, kept so a calibration can re-centre without waiting for the next
  /// line change. A reference box: remembering never invalidates the body.
  @State private var conveyorMemory = ConveyorMemory()
  /// The transcript stays invisible until the conveyor has first measured itself centred: the
  /// opening placement takes a few layout passes (rows arriving, calibration converging), and
  /// showing them read as a stray scroll before the jump to the playhead.
  @State private var revealed = false
  @Environment(\.dismiss) private var dismiss
  /// Whatever mask was in force when this sheet appeared (the player may pin portrait);
  /// restored on dismissal so the sheet's rotation freedom never leaks to its presenter.
  @State private var restoredOrientationLock: UIInterfaceOrientationMask?

  var body: some View {
    GeometryReader { geometry in
      // Sideways is a mode, not a layout: the reading display replaces everything —
      // navigation, banners, transport — with nothing but text (see KaraokeLegibilityView).
      // Rotating back restores the full surface; the model underneath never notices.
      // Wider-than-tall is measured from our own geometry, not size classes — inside a
      // presented sheet the trait collection is the presentation's business, and it differs
      // by device class; the sheet's actual shape doesn't.
      if isLegibilityLayout(geometry), model.state == .ready {
        KaraokeLegibilityView(model: model)
      } else {
        portraitBody
      }
    }
    .task {
      restoredOrientationLock = AppDelegate.orientationLock
      AppDelegate.orientationLock = .all
      await model.start()
      #if DEBUG
      if DebugLaunchOptions.autoDeviceTranscribe {
        for _ in 0..<20 where model.state == .loading {
          try? await Task.sleep(for: .milliseconds(500))
        }
        // .ready too: a resume run re-transcribes any holes, backfills silence, and uploads —
        // which is also how a locally-complete book that never reached the server gets there.
        if model.state == .missingTranscript || model.state == .ready {
          model.startDeviceTranscription()
        }
      }
      #endif
      #if SPEAKER_STACK
      if let speaker {
        SpeakerSessionManager.shared.sheetAttached(speaker)
        await speaker.activate()
      }
      #endif
    }
    .onDisappear {
      if let restoredOrientationLock {
        AppDelegate.orientationLock = restoredOrientationLock
      }
      model.stop()
      #if SPEAKER_STACK
      // Not a plain deactivate: while the speaker is playing this book, the session (and its WS
      // monitor) must outlive the sheet, or every surface outside it goes stale and reopening
      // rewinds playback. The manager keeps it alive exactly as long as the speaker session runs.
      if let speaker {
        SpeakerSessionManager.shared.sheetDismissed(speaker)
      }
      #endif
    }
  }

  private func isLegibilityLayout(_ geometry: GeometryProxy) -> Bool {
    #if DEBUG
    if DebugLaunchOptions.legibilityPreview { return true }
    #endif
    return geometry.size.width > geometry.size.height
  }

  private var portraitBody: some View {
    NavigationStack {
      Group {
        switch model.state {
        case .loading:
          ProgressView("Loading transcript…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noAudio:
          ContentUnavailableView {
            Label("No Audio", systemImage: "book.closed")
          } description: {
            Text("This item is an ebook — there is no audio to transcribe.")
          }
        case .storeUnavailable:
          ContentUnavailableView {
            Label("Transcript Storage Unavailable", systemImage: "externaldrive.badge.xmark")
          } description: {
            Text("The local transcript database couldn't be opened.")
          }
        case .missingTranscript:
          missingPanel
        case .ready:
          transcript
        }
      }
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        #if SPEAKER_STACK
        if let speaker {
          transportBar(speaker)
        }
        #else
        localBar
        #endif
      }
      .safeAreaInset(edge: .top) {
        // Transcription continues behind the transcript once the first chunks land; this keeps the
        // progress visible without stealing the reading surface. Tap to dismiss once finished.
        if model.state == .ready, let status = model.deviceStatusText {
          HStack(spacing: 10) {
            if model.deviceActive {
              ProgressView(value: model.deviceFraction)
                .frame(width: 90)
            }
            Text(status)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer()
            if model.deviceActive {
              Button("Cancel", role: .destructive) { model.cancelDeviceTranscription() }
                .font(.footnote)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(.ultraThinMaterial)
          .onTapGesture {
            model.acknowledgeDeviceStatus()
          }
        }

        // The cleanup surface lives here rather than in the toolbar: it only matters while raw
        // ASR is on screen, and the banner is already the sheet's "work in progress" strip.
        if model.state == .ready, let status = model.cleanupStatusText {
          HStack(spacing: 10) {
            if model.cleanupActive {
              ProgressView(value: model.cleanupFraction)
                .frame(width: 90)
            }
            Text(status)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer()
            if model.cleanupActive {
              Button("Cancel", role: .destructive) { model.cancelCleanup() }
                .font(.footnote)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(.ultraThinMaterial)
          .onTapGesture {
            model.acknowledgeCleanupStatus()
          }
        } else if model.state == .ready, model.cleanupOffered {
          Button {
            model.startCleanup()
          } label: {
            Label("Clean Up Text", systemImage: "wand.and.sparkles")
              .font(.footnote)
              .frame(maxWidth: .infinity)
          }
          .padding(.vertical, 8)
          .background(.ultraThinMaterial)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        // The chapter control lives where the title was: arrows plus a long title never fit an
        // iPhone bar (the arrows just sat on top of the text). Also shown in .missingTranscript —
        // browsing into an untranscribed span swaps the surface to the request panel, and this
        // menu is then the way back out.
        if !model.chapters.isEmpty, model.state == .ready || model.state == .missingTranscript {
          ToolbarItem(placement: .principal) {
            Button {
              showChapterPicker = true
            } label: {
              HStack(spacing: 4) {
                Text(model.currentChapterTitle ?? String(localized: "Chapters"))
                  .font(.headline)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                Image(systemName: "chevron.down")
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(.secondary)
              }
              // A principal item is centred at its ideal width, not constrained — an unbounded
              // title slides under the Done button. 250pt clears every bar this app runs on.
              .frame(maxWidth: 250)
            }
            .accessibilityLabel("Chapters")
            .accessibilityValue(model.currentChapterTitle ?? "")
          }
        }
      }
      .sheet(isPresented: $showChapterPicker) {
        chapterPicker
      }
    }
  }

  private var navigationTitle: String {
    #if SPEAKER_STACK
    return model.currentChapterTitle ?? (speaker?.hasOwnSession == true ? "Speaker" : "Transcript")
    #else
    return model.currentChapterTitle ?? "Transcript"
    #endif
  }

  // MARK: - Chapter picker

  /// The title dropdown. Selecting a chapter *browses* — the transcript jumps there while playback
  /// stays put (tapping a line is what seeks); re-selecting the playing chapter returns to the
  /// playhead instead. The playing chapter is marked, and the list opens scrolled to it.
  private var chapterPicker: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        List(model.chapters) { marker in
          chapterRow(marker)
        }
        .listStyle(.plain)
        .onAppear {
          if let index = model.currentChapterIndex {
            proxy.scrollTo(model.chapters[index].id, anchor: .center)
          }
        }
      }
      .navigationTitle("Chapters")
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium, .large])
  }

  private func chapterRow(_ marker: Model.ChapterMarker) -> some View {
    let isCurrent = model.currentChapterIndex.map { model.chapters[$0].id == marker.id } ?? false
    return Button {
      model.browseToChapter(marker)
      showChapterPicker = false
    } label: {
      HStack(spacing: 10) {
        Text(marker.title)
          .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
          .fontWeight(isCurrent ? .semibold : .regular)
        Spacer()
        Text(Duration.seconds(marker.start).formatted(.time(pattern: chapterTimePattern)))
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.secondary)
        if isCurrent {
          Image(systemName: "waveform")
            .font(.footnote)
            .foregroundStyle(.tint)
            .accessibilityLabel("Currently playing")
        }
      }
    }
  }

  /// One pattern for the whole list so the trailing column stays aligned, sized by book length.
  private var chapterTimePattern: Duration.TimeFormatStyle.Pattern {
    (model.chapters.last?.end ?? 0) >= 3600 ? .hourMinuteSecond : .minuteSecond
  }

  // MARK: - Transport

  #if !SPEAKER_STACK
  /// The store build's bottom bar: plain local transport. The speaker-aware bars live below,
  /// compiled only into the personal build.
  private var localBar: some View {
    Button {
      toggleLocalPlayback()
    } label: {
      Label(
        localIsPlaying ? "Pause" : "Play on iPhone",
        systemImage: localIsPlaying ? "pause.fill" : "iphone"
      )
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
  }
  #endif

  #if SPEAKER_STACK
  /// The sheet's bottom bar. When the speaker is the *active* output it's the full speaker
  /// transport; otherwise it's the local transport plus the handoff button — so the transcript is
  /// one surface that controls playback wherever playback actually is.
  ///
  /// The branch goes through the manager's `activeSession`, the same hook every other transport
  /// uses — not the attached session's own `hasOwnSession`. The difference bit this in the wild:
  /// a paused daemon session lingering from an earlier handoff made the sheet show "Paused on
  /// Speaker" while the phone was audibly mid-chapter.
  @ViewBuilder
  private func transportBar(_ speaker: SpeakerSessionModel) -> some View {
    if let live = SpeakerSessionManager.shared.activeSession(for: model.itemID) {
      speakerBar(live)
    } else {
      outputBar(speaker)
    }
  }

  /// Playback isn't on the speaker (yet): local play/pause for this book, and the handoff button.
  private func outputBar(_ speaker: SpeakerSessionModel) -> some View {
    VStack(spacing: 8) {
      if speaker.isForeignSession {
        Text("The speaker is playing something else — Play on Speaker replaces it.")
          .font(.caption2)
          .foregroundStyle(.orange)
      }

      HStack(spacing: 14) {
        Button {
          toggleLocalPlayback()
        } label: {
          Label(
            localIsPlaying ? "Pause" : "Play on iPhone",
            systemImage: localIsPlaying ? "pause.fill" : "iphone"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        if CompanionStore.shared.supportsSpeaker {
          Button {
            // Same handoff the player menu does: the speaker takes over from the transcript's
            // playhead, so local playback stops first. While idle, a seek *is* play-at-position.
            PlayerManager.shared.pause()
            speaker.seek(to: model.position)
          } label: {
            Label("Play on Speaker", systemImage: "hifispeaker")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
        }
      }

      if speaker.actionFailed {
        Text("Couldn't reach the speaker controller.")
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
  }

  #endif

  private var localIsPlaying: Bool {
    let player = PlayerManager.shared
    return player.current?.id == model.itemID && player.current?.isPlaying == true
  }

  private func toggleLocalPlayback() {
    let player = PlayerManager.shared
    if let current = player.current, current.id == model.itemID {
      current.isPlaying ? player.pause() : player.play()
    } else {
      // Menu-launched transcript for a book that isn't loaded: start it here. Playback resumes
      // from saved progress, which is exactly the transcript's playhead.
      Task { await player.play(model.itemID) }
    }
  }

  #if SPEAKER_STACK
  /// Controls routed through the daemon, so Home Assistant sees every change and its own changes
  /// show up here via the WS within a second.
  private func speakerBar(_ speaker: SpeakerSessionModel) -> some View {
    VStack(spacing: 10) {
      HStack {
        Image(systemName: "hifispeaker")
          .foregroundStyle(.secondary)
        Text(speakerStatusLine(speaker))
          .font(.footnote)
          .foregroundStyle(.secondary)
        Spacer()
        Menu {
          Button("Continue on iPhone", systemImage: "iphone") {
            speaker.continueOnPhone()
            dismiss()
          }
          Button("Stop Speaker", systemImage: "stop.circle", role: .destructive) {
            speaker.stopSpeaker()
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }

      if speaker.isForeignSession {
        Text("The speaker is playing something else — Play replaces it.")
          .font(.caption2)
          .foregroundStyle(.orange)
      }

      HStack(spacing: 44) {
        Button {
          speaker.skip(-30)
        } label: {
          Image(systemName: "gobackward.30").font(.title2)
        }
        .disabled(!speaker.hasOwnSession)

        Button {
          speaker.togglePlayback()
        } label: {
          Image(systemName: speaker.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 52))
        }

        Button {
          speaker.skip(30)
        } label: {
          Image(systemName: "goforward.30").font(.title2)
        }
        .disabled(!speaker.hasOwnSession)
      }

      HStack(spacing: 12) {
        Image(systemName: "speaker.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
        Slider(value: Bindable(speaker).volume, in: 0...100) { editing in
          if !editing { speaker.commitVolume() }
        }
        Image(systemName: "speaker.wave.3.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if speaker.actionFailed {
        Text("Couldn't reach the speaker controller.")
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
  }

  private func speakerStatusLine(_ speaker: SpeakerSessionModel) -> String {
    guard let remote = speaker.remote else { return "Connecting to speaker…" }
    if speaker.isForeignSession {
      return "Playing: \(remote.title ?? "another book")"
    }
    switch remote.state {
    case "playing": return "Playing on speaker"
    case "paused": return "Paused on speaker"
    default: return "Speaker idle — tap play to start here"
    }
  }
  #endif

  // MARK: - No transcript: the transcription surface

  @ViewBuilder
  private var missingPanel: some View {
    #if SPEAKER_STACK
    if model.deviceActive {
      devicePanel
    } else if let job = model.worker?.job, job.isActive {
      VStack(spacing: 20) {
        ProgressView(value: min(max((job.pct ?? 0) / 100, 0), 1))
          .padding(.horizontal, 44)
        Text(progressLine(for: job))
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Cancel Transcription", role: .destructive) {
          model.cancelServerTranscription()
        }
        if model.jobActionFailed {
          Text("Couldn't reach the transcription server.")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      .padding()
    } else {
      requestPanel
    }
    #else
    if model.deviceActive {
      devicePanel
    } else {
      requestPanel
    }
    #endif
  }

  /// Whether the panel's footnote comparing iPhone and server has a server to compare with.
  private var offersServerAlternative: Bool {
    #if SPEAKER_STACK
    model.canTranscribeOnServer
    #else
    false
    #endif
  }

  private var requestPanel: some View {
    ContentUnavailableView {
      Label("No Transcript Yet", systemImage: "text.bubble")
    } description: {
      Text(missingDescription)
    } actions: {
      VStack(spacing: 10) {
        if model.deviceSupported {
          // The default: measured ~85x realtime on this hardware, ~19x faster than the server.
          Button {
            model.startDeviceTranscription()
          } label: {
            Label(
              "Transcribe on iPhone · ≈\(model.deviceEstimateMinutes) min",
              systemImage: "iphone.gen3"
            )
          }
          .buttonStyle(.borderedProminent)
        }
        #if SPEAKER_STACK
        if model.canTranscribeOnServer {
          Button(
            model.worker?.coverage.hasTranscript == true
              ? "Resume on Server" : "Transcribe on Server"
          ) {
            model.requestServerTranscription()
          }
          .buttonStyle(.bordered)
        }
        #endif
        if model.deviceSupported, offersServerAlternative {
          Text("iPhone keeps the app open for a few minutes; the server takes hours but runs unattended.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
      }
      #if SPEAKER_STACK
      if model.jobActionFailed {
        Text("Couldn't reach the transcription server.")
          .font(.footnote)
          .foregroundStyle(.red)
      }
      #endif
      // A device run that failed or was cancelled lands back on this screen — without this line
      // the failure would be invisible, which reads as "I hit start and nothing happened."
      if !model.deviceActive, let status = model.deviceStatusText {
        Text(status)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .onTapGesture { model.acknowledgeDeviceStatus() }
      }
    }
  }

  /// On-device transcription in flight while there's nothing to read yet. Once the first chunks
  /// commit, the sheet flips to the transcript and progress moves to the top banner.
  private var devicePanel: some View {
    VStack(spacing: 20) {
      ProgressView(value: model.deviceFraction)
        .padding(.horizontal, 44)
      VStack(spacing: 4) {
        Text(model.deviceStatusText ?? "Transcribing on iPhone…")
          .font(.callout)
          .foregroundStyle(.secondary)
        if model.deviceRate > 1 {
          Text("\(Int(model.deviceRate))× realtime")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .multilineTextAlignment(.center)
      Button("Cancel", role: .destructive) {
        model.cancelDeviceTranscription()
      }
    }
    .padding()
  }

  private var missingDescription: String {
    guard offersServerAlternative else {
      return "This book doesn't have a transcript yet."
    }
    guard let worker = model.worker else {
      return "The server hasn't transcribed this book yet."
    }
    if let job = worker.job, job.state == .error {
      return "The last transcription attempt failed. You can try again."
    }
    if worker.coverage.hasTranscript {
      // A cancelled or still-running job leaves a real-but-partial transcript; playback is past it.
      let covered = Duration.seconds(worker.coverage.coveredSecs)
        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
      return "The server transcript covers the first \(covered) of this book, and playback is past it."
    }
    return
      "The server hasn't transcribed this book yet. Transcription runs on your server, not on this device, and takes roughly a quarter of the book's length."
  }

  private func progressLine(for job: TranscriptionJob) -> String {
    var parts: [String] = []
    if let pct = job.pct {
      parts.append("\(Int(pct))%")
    }
    if let eta = job.etaSecs, eta > 0 {
      let remaining = Duration.seconds(eta)
        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
      parts.append("about \(remaining) left")
    }
    let detail = parts.isEmpty ? "starting…" : parts.joined(separator: " · ")
    return "Transcribing on your server — \(detail)"
  }

  // MARK: - Transcript

  private var transcript: some View {
    // Follow-mode is a teleprompter, not a scroll view — the lesson imported from the landscape
    // reading mode, where nothing ever felt jumpy because nothing scrolls: the reading position
    // is fixed and the *content* repositions. While following, scrolling is disabled and the
    // whole column sits at an analytic offset (viewport middle minus the active row's measured
    // position). One animated glide per line change; between line changes no positioning code
    // runs at all, and anything that shifts layout (an import replacing rows, a banner) is
    // compensated in the same frame by the measurement changing. Browsing is the ordinary
    // ScrollView with native physics; the first pan hands off seamlessly.
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ForEach(model.rows) { row in
              switch row {
              case .chapter(let marker):
                chapterHeader(marker)
              case .line(let index, let segment):
                line(segment, isActive: index == model.activeIndex, isPast: index < model.activeIndex)
                  .onTapGesture {
                    // Nudge back slightly so the tapped line's first word isn't already gone by
                    // the time playback resumes — same 0.3s the reference player uses. Tapping a
                    // line makes it the playhead, so tracking resumes from it.
                    model.seek(to: max(0, segment.start - 0.3))
                    model.follow = true
                  }
                  .anchorPreference(key: ActiveRowAnchorKey.self, value: .center) {
                    row.id == model.activeRowID ? $0 : nil
                  }
              }
            }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 32)
          // The active row's centre, measured in content space (offset-independent), feeds the
          // conveyor. The target only changes on a line change or a real layout change, so the
          // word-glow ticks drive zero repositioning work.
          .backgroundPreferenceValue(ActiveRowAnchorKey.self) { anchor in
            GeometryReader { content in
              let target = ConveyorTarget(
                id: model.follow ? model.activeRowID : nil,
                midY: anchor.map { content[$0].y },
                viewportHeight: viewport.size.height
              )
              Color.clear
                .onChange(of: target, initial: true) { _, target in
                  updateConveyor(target, viewportHeight: viewport.size.height)
                }
            }
          }
          .anchorPreference(key: ContentBoundsKey.self, value: .bounds) { $0 }
          .offset(y: model.follow ? conveyorOffset : residualOffset)
          .opacity(revealed ? 1 : 0)
        }
        .modifier(
          TouchHandoff(
            isFollowing: model.follow,
            conveyorOffset: $conveyorOffset,
            residualOffset: $residualOffset,
            parkRequest: parkRequest
          ) { positioned in
            panHandoff = positioned
            model.follow = false
          }
        )
        // Calibration: where the content's origin actually sits in viewport space, measured
        // rather than derived from inset arithmetic (scroll content origins, safe-area insets,
        // and banners all conspire; measuring is truth). `contentBase` is the origin's resting
        // position with zero conveyor offset — captured only while following (a finger on the
        // scroll view ends following) and no glide is in flight, so it can never chase its own
        // animation.
        .overlayPreferenceValue(ContentBoundsKey.self) { bounds in
          GeometryReader { outer in
            // Paired with the offset in force for this same layout pass: a measurement is only
            // meaningful against the offset it was taken under, and handlers can run after the
            // offset has already moved on.
            let sample = bounds.map { CalibrationSample(top: outer[$0].minY, offset: conveyorOffset) }
            Color.clear
              .onChange(of: sample, initial: true) { _, sample in
                calibrate(sample)
              }
          }
          .allowsHitTesting(false)
        }
        // Reader paging while browsing: nearing either end of the loaded window loads more.
        // Model-guarded no-ops while following. iOS 17 (the app's floor, which no device here
        // runs) simply doesn't page past the window.
        .modifier(
          ScrollEdgePaging(onTop: { model.pageBackward() }, onBottom: { model.pageForward() })
        )
        // Chapter browsing lands here once the model has the target's rows loaded. Jump, don't
        // glide — the list content was just replaced wholesale. Headers pin to the top; the
        // active line, when the playing chapter was re-selected, re-centres via the conveyor.
        .onChange(of: model.browseScrollRowID, initial: true) { _, id in
          guard let id else { return }
          proxy.scrollTo(id, anchor: id.hasPrefix("chapter-") ? .top : .center)
          model.browseScrollHandled()
        }
        // Leaving follow for any non-pan reason (chapter browse): the conveyor offset drops to
        // zero in the same pass, so park the real scroll where the reader was looking — the
        // browse target then repositions from there.
        .onChange(of: model.follow) { _, follows in
          if follows {
            return
          }
          revealed = true
          conveyorActiveID = nil
          if panHandoff {
            panHandoff = false
          } else if let id = model.activeRowID {
            residualOffset = 0
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              proxy.scrollTo(id, anchor: .center)
            }
          }
        }
        .overlay(alignment: .bottom) {
          Group {
            if !model.follow, model.state == .ready {
              Button {
                model.returnToPlayhead()
              } label: {
                Label("Back to Playhead", systemImage: "waveform")
                  .font(.footnote.weight(.semibold))
                  .padding(.horizontal, 14)
                  .padding(.vertical, 9)
                  .background(.regularMaterial, in: Capsule())
              }
              .buttonStyle(.plain)
              .padding(.bottom, 14)
              .transition(.move(edge: .bottom).combined(with: .opacity))
            }
          }
          .animation(.easeInOut(duration: 0.2), value: model.follow)
        }
        // Never stay hidden: if calibration can't converge (an odd layout, a window with nothing
        // to centre), show the text anyway.
        .task {
          try? await Task.sleep(for: .seconds(1.5))
          revealed = true
        }
      }
    }
  }

  /// One glide per line change; silent, exact compensation when layout shifts under the same
  /// line. This is the entire follow-mode positioning logic — nothing else moves the text.
  ///
  /// `screen(midY) = contentBase + conveyorOffset + midY`, so centring solves to
  /// `offset = H/2 − midY − contentBase`. Absolute, not incremental — it can't accumulate error,
  /// and retargeting mid-glide converges on the same answer.
  private func updateConveyor(_ target: ConveyorTarget, viewportHeight: CGFloat) {
    guard model.follow, let id = target.id, let midY = target.midY else { return }
    conveyorMemory.midY = midY
    conveyorMemory.viewportHeight = viewportHeight
    let offset = viewportHeight / 2 - midY - contentBase
    if id != conveyorActiveID {
      conveyorActiveID = id
      conveyorMemory.parkRequestedAt = nil
      // A glide is for the next line or a tap nearby. Anything farther — opening the sheet,
      // returning from far away, a seek — jumps: a 0.3s glide across thousands of points is a
      // blur of scrolling text, not a transition.
      guard abs(offset - conveyorOffset) <= viewportHeight / 2 else {
        conveyorOffset = offset
        settle(for: 0.05)
        return
      }
      withAnimation(.easeOut(duration: 0.3)) {
        conveyorOffset = offset
      }
      // Calibration sits out the glide, and a layout change that lands inside it (rows replaced
      // as the window reloads) would otherwise never be measured — the line then stays off-centre
      // until the *next* line change, which while paused is never. Re-check once it's over.
      settle(for: 0.35)
    } else if Date() >= glideUntil, abs(offset - conveyorOffset) > 1 {
      conveyorOffset = offset
    }
  }

  /// Fold a fresh measurement of the content origin into `contentBase`, and re-centre if it
  /// moved: the base only changes when something moved the content under the conveyor (a reload
  /// racing a glide, a banner, the scroll view settling), and the offset computed from the stale
  /// base is off by exactly that much. Converges in one step — the re-centred layout measures
  /// back to the same base.
  private func calibrate(_ sample: CalibrationSample?) {
    conveyorMemory.sample = sample
    guard model.follow, let sample, Date() >= glideUntil else { return }
    let base = sample.top - sample.offset
    if abs(base - contentBase) > 0.5 {
      contentBase = base
    }
    // Re-centre against everything current — base, row position, viewport height — for the row
    // the conveyor already committed to. A fresh target (a line change, a return to the
    // playhead) is `updateConveyor`'s to deliver, not a silent snap's.
    if let midY = conveyorMemory.midY, conveyorActiveID != nil,
      conveyorActiveID == model.activeRowID
    {
      let offset = conveyorMemory.viewportHeight / 2 - midY - contentBase
      if abs(offset - conveyorOffset) > 1 {
        conveyorOffset = offset
        return  // park once this lands and measures back
      }
    }
    if !revealed {
      withAnimation(.easeOut(duration: 0.15)) { revealed = true }
    }
    // Centred and measured under the offset in force: fold it into the scroll view, so a
    // finger finds the scroll view already where the text is. A park moves both coordinates
    // in one pass; sit out a beat before trusting measurements again.
    // Once per settled offset: a park the scroll view can't take (the window's very start or
    // end, or iOS 17) leaves the offset as is, and asking again would only spin.
    if abs(conveyorOffset) <= 0.5 {
      conveyorMemory.parkRequestedAt = nil
    } else if abs(sample.offset - conveyorOffset) < 0.5,
      conveyorMemory.parkRequestedAt != conveyorOffset
    {
      conveyorMemory.parkRequestedAt = conveyorOffset
      settle(for: 0.12)
      parkRequest += 1
    }
  }

  /// Hold calibration off while positions are in motion, then re-measure once they've landed.
  private func settle(for seconds: TimeInterval) {
    glideUntil = Date().addingTimeInterval(seconds)
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds + 0.03))
      calibrate(conveyorMemory.sample)
    }
  }

  private func chapterHeader(_ marker: Model.ChapterMarker) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Text(marker.title)
        .font(.footnote.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 14)
    .onTapGesture {
      model.seek(to: marker.start)
      model.follow = true
    }
  }

  private func line(_ segment: TranscriptSegment, isActive: Bool, isPast: Bool) -> some View {
    TranscriptLine(model: model, segment: segment, isActive: isActive, isPast: isPast)
  }
}

/// One glyph stream and one weight for every state — activation changes COLOR ONLY.
///
/// A weight flip (regular↔medium) or a source-string switch (plain text ↔ word-piece join)
/// rewraps the paragraph, which shifts everything below it: the "text jumps when the highlight
/// moves" bug, discovered once in the cover view and again here. So every line renders from
/// `TranscriptText.stream` at a fixed weight, and highlighting only recolors.
///
/// Its own view so only the *active* line reads the playhead: the ~30Hz highlight clock then
/// re-renders one row, not every attributed string in the window (which also kept drags smooth).
private struct TranscriptLine: View {
  let model: KaraokeSheet.Model
  let segment: TranscriptSegment
  let isActive: Bool
  let isPast: Bool

  var body: some View {
    Text(
      TranscriptText.styled(
        segment,
        position: isActive ? model.position : 0,
        isActive: isActive,
        active: .accentColor,
        pending: Color(.secondaryLabel),
        rest: isActive
          ? Color(.label)
          : (isPast ? Color(.tertiaryLabel) : Color(.secondaryLabel))
      )
    )
    .font(.title3.weight(.medium))
  }
}

/// Browsing starts with the reader's first touch, natively: no dead zone, real momentum, real
/// rubber-banding. The scroll view stays live while following, and between line changes it is
/// *parked* where the text actually is — each settled glide folds the conveyor offset into the
/// real scroll offset in one invisible transaction (same screen position, different coordinates).
/// A finger therefore lands on a scroll view that already agrees with what's on screen, and
/// following simply ends. Parking has to happen at rest: an offset written while a finger is down
/// is overwritten by the pan on its next move (measured — the text snapped to the window's top).
///
/// A touch that lands mid-glide inherits the unparked remainder as a residual offset, folded in
/// the same way once that scroll comes to rest.
///
/// Replaces a gesture that moved the conveyor 1:1 behind a 12pt threshold and stopped dead on
/// release, which read as a lock the reader had to break before the text would really scroll.
private struct TouchHandoff: ViewModifier {
  let isFollowing: Bool
  @Binding var conveyorOffset: CGFloat
  @Binding var residualOffset: CGFloat
  /// Bumped by the sheet when the conveyor has settled and can be folded into the scroll view.
  let parkRequest: Int
  /// Ends following; the flag says whether the handoff already positioned the scroll view.
  let takeOver: (_ positioned: Bool) -> Void

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content.modifier(
        NativeTouchHandoff(
          isFollowing: isFollowing,
          conveyorOffset: $conveyorOffset,
          residualOffset: $residualOffset,
          parkRequest: parkRequest,
          takeOver: takeOver
        )
      )
    } else {
      // iOS 17 has no scroll-phase or offset APIs: keep the conveyor exclusive, and let a drag
      // simply end following — the follow-exit hook parks the scroll on the (centred) active row.
      content
        .scrollDisabled(isFollowing)
        .simultaneousGesture(
          DragGesture(minimumDistance: 12).onChanged { _ in
            guard isFollowing else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { takeOver(false) }
          }
        )
    }
  }
}

@available(iOS 18.0, *)
private struct NativeTouchHandoff: ViewModifier {
  let isFollowing: Bool
  @Binding var conveyorOffset: CGFloat
  @Binding var residualOffset: CGFloat
  let parkRequest: Int
  let takeOver: (_ positioned: Bool) -> Void
  @State private var position = ScrollPosition(idType: String.self)
  /// Live scroll metrics, read when parking. A reference box so per-frame scroll updates never
  /// invalidate a body.
  @State private var metrics = ScrollMetricsBox()

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
        // `scrollTo(y:)` speaks inset-adjusted offsets: 0 is the content's top at rest.
        ScrollMetrics(
          y: geometry.contentOffset.y + geometry.contentInsets.top,
          maxY: geometry.contentSize.height + geometry.contentInsets.top
            + geometry.contentInsets.bottom - geometry.containerSize.height
        )
      } action: { _, new in
        metrics.value = new
      }
      .onChange(of: parkRequest) {
        guard isFollowing else { return }
        park(&conveyorOffset)
      }
      .onScrollPhaseChange { _, phase in
        if phase == .interacting, isFollowing {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            residualOffset = conveyorOffset
            takeOver(true)
          }
        } else if phase == .idle, !isFollowing, residualOffset != 0 {
          park(&residualOffset)
        }
      }
  }

  /// Move `offset`'s worth of displacement from the `.offset` modifier into the scroll view,
  /// leaving the screen unchanged. Skipped where the scroll view can't reach (the window's very
  /// start or end) — the offset then just stays on the conveyor, as it always did.
  private func park(_ offset: inout CGFloat) {
    guard abs(offset) > 0.5 else { return }
    let target = metrics.value.y - offset
    guard target >= 0, target <= metrics.value.maxY else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      position.scrollTo(y: target)
      offset = 0
    }
  }
}

private struct ScrollMetrics: Equatable {
  var y: CGFloat = 0
  var maxY: CGFloat = 0
}

private final class ScrollMetricsBox {
  var value = ScrollMetrics()
}

/// See `conveyorMemory`.
private final class ConveyorMemory {
  var midY: CGFloat?
  var viewportHeight: CGFloat = 0
  var sample: CalibrationSample?
  var parkRequestedAt: CGFloat?
}

/// The content origin's measured viewport position and the conveyor offset it was measured under.
private struct CalibrationSample: Equatable {
  let top: CGFloat
  let offset: CGFloat
}

/// The teleprompter's input: which row should be centred and where its centre currently sits in
/// content space. Equatable so the measurement hook fires only on real changes — never on the
/// 200ms word-glow ticks.
private struct ConveyorTarget: Equatable {
  let id: String?
  let midY: CGFloat?
  /// Part of the target because the centre moves with it: the sheet presents at one height and
  /// settles at another once its bars take their space.
  let viewportHeight: CGFloat
}

/// The active row's centre anchor, published by whichever row is active.
private struct ActiveRowAnchorKey: PreferenceKey {
  static var defaultValue: Anchor<CGPoint>? = nil
  static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
    value = value ?? nextValue()
  }
}

/// The whole text column's bounds — the conveyor's coordinate calibration (see `contentBase`).
private struct ContentBoundsKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// Near-edge detection for reader paging, availability-wrapped: `onScrollGeometryChange` is
/// iOS 18+, and the app's floor is 17 for upstream parity. Values: -1 near top, 1 near bottom,
/// 0 in the middle; the action fires only on membership *changes*, so each edge visit pages once
/// and re-arms when new content pushes the edge away.
private struct ScrollEdgePaging: ViewModifier {
  let onTop: () -> Void
  let onBottom: () -> Void

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content
        .onScrollGeometryChange(for: Int.self) { geometry in
          let offset = geometry.contentOffset.y + geometry.contentInsets.top
          if offset < 300 { return -1 }
          let bottomGap =
            geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y
          if bottomGap < 300 { return 1 }
          return 0
        } action: { _, edge in
          if edge == -1 { onTop() }
          if edge == 1 { onBottom() }
        }
    } else {
      content
    }
  }
}

/// Shared stable-layout text builder for the karaoke surfaces.
///
/// The invariant both views rely on: for a given segment, the returned string's characters are
/// identical no matter the highlight state — only colors differ — so activation can never rewrap.
enum TranscriptText {
  /// The one canonical character stream for a segment: the word-piece join when timings exist
  /// (with the join's leading whitespace trimmed — the raw pieces carry a leading space), the
  /// plain text otherwise.
  ///
  /// - Parameters:
  ///   - active: spoken-word color while the line is active (word-timed segments only).
  ///   - pending: not-yet-spoken color while the line is active.
  ///   - rest: the whole line's color when it isn't active (or has no timings and is active —
  ///     pass the active color in that case).
  static func styled(
    _ segment: TranscriptSegment,
    position: TimeInterval,
    isActive: Bool,
    active: Color,
    pending: Color,
    rest: Color
  ) -> AttributedString {
    guard let words = segment.words, !words.isEmpty else {
      var plain = AttributedString(segment.text)
      plain.foregroundColor = rest
      return plain
    }
    var result = AttributedString()
    for (index, word) in words.enumerated() {
      let text = index == 0 ? String(word.text.drop(while: \.isWhitespace)) : word.text
      var piece = AttributedString(text)
      if isActive {
        piece.foregroundColor = word.start <= position ? active : pending
      } else {
        piece.foregroundColor = rest
      }
      result += piece
    }
    return result
  }
}
