import API
import Foundation
import Models
import SwiftUI
import Transcription

extension KaraokeSheet {
  /// Drives the karaoke view: tracks the playhead, keeps transcript around it, picks the active line,
  /// and manages the host transcription job when there is no transcript to show.
  ///
  /// Two loops with very different costs, deliberately separated:
  /// - a 200ms **ticker** that only reads the playhead and re-picks the active line (pure local work,
  ///   ported from the reference player's render loop), and
  /// - a 2s **maintenance** pass that owns everything with I/O — importing missing chunks, loading the
  ///   window from the store, and polling the worker. Folding these into one fast loop is how you get
  ///   five HTTP requests per second against a book that has no transcript.
  @MainActor
  @Observable
  final class Model {
    enum State: Equatable {
      case loading
      case ready
      /// Ebook-only item: no audio exists, so transcription can never apply. 31 of the 48 items in
      /// this library are in this state — it's ordinary, not an error.
      case noAudio
      /// The item has audio but nothing local for the current window — the job UI's territory.
      case missingTranscript
      case storeUnavailable
    }

    /// A chapter boundary, mapped from the player's existing chapter data — no separate fetch.
    struct ChapterMarker: Equatable, Identifiable {
      let id: Int
      let title: String
      let start: TimeInterval
      let end: TimeInterval
    }

    /// What the transcript list renders: lines with chapter headers interleaved at the boundaries
    /// that fall inside the loaded window.
    enum Row: Equatable, Identifiable {
      case chapter(ChapterMarker)
      case line(index: Int, segment: TranscriptSegment)

      var id: String {
        switch self {
        case .chapter(let marker): "chapter-\(marker.id)"
        case .line(_, let segment): "seg-\(segment.seg)"
        }
      }
    }

    private(set) var state: State = .loading
    /// Segments in the currently loaded window.
    private(set) var segments: [TranscriptSegment] = []
    /// The render list: segments with chapter headers interleaved. Rebuilt when the window changes.
    private(set) var rows: [Row] = []
    private(set) var activeIndex: Int = -1
    private(set) var position: TimeInterval = 0
    /// Identity of the active line, so the view only scrolls when the line actually changes.
    private(set) var activeSegmentID: Int?
    /// Row id of the active line — the scroll target.
    private(set) var activeRowID: String?
    private(set) var currentChapterIndex: Int?
    /// The worker's view of this item: host coverage watermark plus the newest job.
    private(set) var worker: WorkerStatus?
    private(set) var jobActionFailed = false

    /// Mirrored from the on-device transcription session each ticker pass, so the view observes
    /// plain model state and the iOS-26-only session type stays contained.
    private(set) var deviceActive = false
    private(set) var deviceFraction: Double = 0
    private(set) var deviceRate: Double = 0
    private(set) var deviceTrack: (current: Int, total: Int) = (0, 0)
    private(set) var deviceStatusText: String?
    /// Whether this device can transcribe at all (iOS 26 API present and the item has audio).
    private(set) var deviceSupported = false
    /// Conservative whole-book estimate shown on the button (measured 85x; promised 60x).
    var deviceEstimateMinutes: Int { max(1, Int((duration / 60 / 60).rounded(.up))) }

    /// The running transcription for this book, owned by `TranscriptionJobManager` so it survives
    /// this model (sheet dismissal must not orphan an hour of ANE work) and so a second surface
    /// can't start a duplicate. This model only mirrors it.
    @ObservationIgnored private var deviceSessionBox: AnyObject? {
      get { TranscriptionJobManager.shared.deviceSession(for: itemID) }
      set { TranscriptionJobManager.shared.setDeviceSession(newValue, for: itemID) }
    }

    /// Mirrored from the LLM cleanup session, same containment idea as the device-session mirrors:
    /// the view observes plain state; the iOS-26-only FoundationModels type stays boxed.
    private(set) var cleanupSupported = false
    private(set) var cleanupActive = false
    private(set) var cleanupFraction: Double = 0
    private(set) var cleanupStatusText: String?
    /// Whether the stored transcript still has raw-ASR chunks a cleanup pass could improve.
    private(set) var cleanupHasRawText = false
    /// Show the "Clean Up Text" offer: something to clean, nothing already running or reported.
    var cleanupOffered: Bool {
      cleanupSupported && cleanupHasRawText && !cleanupActive && cleanupStatusText == nil
    }
    /// Manager-owned for the same reasons as `deviceSessionBox`.
    @ObservationIgnored private var cleanupSessionBox: AnyObject? {
      get { TranscriptionJobManager.shared.cleanupSession(for: itemID) }
      set { TranscriptionJobManager.shared.setCleanupSession(newValue, for: itemID) }
    }

    /// Whether to keep the active line centred. Cleared as soon as the user scrolls; re-enabling
    /// recenters the window on the playhead.
    var follow: Bool = true {
      didSet {
        guard follow, !oldValue else { return }
        pendingBrowseRowID = nil
        window = nil
        kick()
      }
    }

    /// Row the view should jump to, published only once that row exists in `rows`. This is the
    /// chapter dropdown's scroll channel: browsing arms a pending target, `maintainNow` publishes
    /// it after the window loads, and the view scrolls then calls `browseScrollHandled()`.
    private(set) var browseScrollRowID: String?
    /// The armed browse target while its window is still loading — it can resolve seconds later
    /// when a still-transcribing span's imports land. Cleared by whatever makes it obsolete:
    /// a seek, re-following, or another browse.
    @ObservationIgnored private var pendingBrowseRowID: String?

    /// Internal, not private: the sheet's output bar needs it to route local play to this book.
    let itemID: String
    private let duration: TimeInterval
    /// Title/author grounding for the cleanup model — how it knows which proper nouns this book
    /// could plausibly contain. Nil is fine; cleanup just loses the name-fixing advantage.
    private let bookContext: String?
    private let onSeek: (TimeInterval) -> Void
    /// Book-absolute playhead source. Local playback reads `MediaProgress`; speaker playback reads
    /// the daemon's interpolated WS ticks. The model doesn't know which — that indirection is what
    /// makes the karaoke view one player with two outputs.
    private let positionProvider: @MainActor () -> TimeInterval

    /// The daemon and worker accept the ABS session token the app already holds — ABS is the
    /// identity provider, so logging into the player is the whole onboarding story. Required when
    /// the endpoints are the Cloudflare Tunnel hostnames; harmless extra header on the tailnet,
    /// where the services don't demand auth.
    private static let absAuthorization: AuthorizationProvider = {
      guard let server = await Audiobookshelf.shared.authentication.server else { return nil }
      return try? await server.freshToken.bearer
    }

    // FORK-BEGIN(server-jobs): the concrete remote/audio wiring is this fork's daemon+worker.
    // The store build takes the #else branch — `remote = nil`, local-only audio — and every
    // consumer degrades gracefully (no import source, no upload, no job UI) because the seams
    // are optional by design.
    #if SPEAKER_STACK
    /// The daemon+worker as one remote — transcript source, provenance-aware upload, and job
    /// orchestration (the `RemoteTranscriptionJobService` refinement drives the server-job UI).
    /// Nil with no companion server, which every consumer already handles.
    private let remote: (any RemoteTranscriptService)? =
      CompanionSettings.supports(.captions)
      ? DaemonRemoteService(endpoint: .current, authorization: Model.absAuthorization)
      : nil
    /// Local files when the book is downloaded, the daemon's authenticated proxy otherwise.
    private let audioProvider: any TranscriptionAudioProvider =
      CompanionSettings.supports(.audio)
      ? CompositeAudioProvider(
        local: BookAudioProvider(),
        daemon: HostTranscriptSource(endpoint: .current, authorization: Model.absAuthorization)
      )
      : BookAudioProvider()
    #else
    private let remote: (any RemoteTranscriptService)? = nil
    private let audioProvider: any TranscriptionAudioProvider = BookAudioProvider()
    #endif
    // FORK-END(server-jobs)
    private var store: TranscriptStore?
    private var ticker: Task<Void, Never>?
    private var maintainer: Task<Void, Never>?
    private var active = false
    private var maintaining = false

    /// The loaded span. Owned explicitly rather than derived from the playhead on every pass: while
    /// `follow` is off this belongs to the user (paging extends it), and recentering it on the
    /// playhead would yank the view back mid-read.
    private var window: ClosedRange<TimeInterval>?

    /// Import back-off. When an import attempt commits nothing, the host has nothing new for this
    /// window — asking again two seconds later is a slow-motion retry storm. Retry only when the
    /// window moves or the worker reports more coverage than it had when we stalled.
    private var stalledWindow: ClosedRange<TimeInterval>?
    private var stalledCoveredSecs: TimeInterval = -1
    private var lastWorkerPoll: Date = .distantPast

    /// Two chunks back gives context to scroll into; four ahead covers ~20 minutes of listening.
    private static let windowBehind: TimeInterval = 2 * TranscriptGrid.span
    private static let windowAhead: TimeInterval = 4 * TranscriptGrid.span
    /// The highlight's clock. Was 200ms against a playhead that itself only moved every 0.5s
    /// (`MediaProgress`), which put words ~0.35s late on average and up to ~0.7s. Local playback
    /// now reads AVPlayer's continuous clock, so the tick rate is the remaining quantum; ~30Hz
    /// keeps it under a frame pair while only the active line re-renders per tick.
    private static let tickInterval: Duration = .milliseconds(33)
    private static let mirrorEveryNTicks = 6
    private static let highlightLead: TimeInterval = 0.05
    private static let maintenanceInterval: Duration = .seconds(2)
    private static let workerPollInterval: TimeInterval = 4

    let chapters: [ChapterMarker]

    /// When set, `segments` holds display pieces of at most this many characters instead of whole
    /// segments — for surfaces with a fixed frame (the cover square), where one run-on sentence
    /// would overflow. Pieces get identities `seg * 64 + piece`, unique and in order.
    private let displayPieceLimit: Int?

    init(
      itemID: String,
      duration: TimeInterval,
      chapters: [ChapterMarker] = [],
      bookContext: String? = nil,
      displayPieceLimit: Int? = nil,
      positionProvider: @escaping @MainActor () -> TimeInterval,
      onSeek: @escaping (TimeInterval) -> Void
    ) {
      self.itemID = itemID
      self.duration = duration
      self.displayPieceLimit = displayPieceLimit
      self.chapters = Self.normalizeTitles(chapters.sorted { $0.start < $1.start })
      self.bookContext = bookContext
      self.positionProvider = positionProvider
      self.onSeek = onSeek
    }

    /// Filename-style chapter metadata ("Harry Potter and the Goblet of Fire - 16" × 37) truncates
    /// to its useless common prefix in a nav title. Strip the prefix all titles share and dress bare
    /// numbers up as "Chapter N"; genuinely descriptive titles share no long prefix and pass through.
    static func normalizeTitles(_ chapters: [ChapterMarker]) -> [ChapterMarker] {
      guard chapters.count >= 3, var prefix = chapters.first?.title else { return chapters }
      for chapter in chapters {
        prefix = String(zip(prefix, chapter.title).prefix { $0 == $1 }.map(\.0))
        if prefix.isEmpty { return chapters }
      }
      guard prefix.count >= 8 else { return chapters }

      return chapters.map { chapter in
        var title = String(chapter.title.dropFirst(prefix.count))
          .trimmingCharacters(in: CharacterSet(charactersIn: " -–—·:.").union(.whitespaces))
        if title.isEmpty {
          title = chapter.title
        } else if title.allSatisfy(\.isNumber) {
          title = "Chapter \(Int(title) ?? 0)"
        }
        return ChapterMarker(id: chapter.id, title: title, start: chapter.start, end: chapter.end)
      }
    }

    func start() async {
      guard duration > 0 else {
        state = .noAudio
        return
      }

      do {
        let serverID = ModelContextProvider.shared.activeServerID ?? "fallback"
        store = try TranscriptStore.shared(for: serverID, appGroup: AppGroup.identifier)
      } catch {
        state = .storeUnavailable
        return
      }

      active = true
      #if !targetEnvironment(simulator)
      if #available(iOS 26.0, *) {
        deviceSupported = true
      }
      #endif
      // Unlike SpeechAnalyzer, FoundationModels links everywhere; availability is a runtime
      // question (Apple Intelligence enabled, model downloaded), so no simulator gate here.
      if #available(iOS 26.0, *) {
        cleanupSupported = CleanupSession.isSupported
      }
      position = clamped(positionProvider())
      await maintainNow()
      startLoops()
      refreshCleanupEligibility()
    }

    // On-device transcription touches iOS-26 Speech types that aren't linkable on the simulator
    // (see DeviceTranscriptionSession), so the whole surface compiles out there. `deviceSupported`
    // stays false on the sim, so none of this is reachable from the UI regardless.
    #if !targetEnvironment(simulator)
    /// Start transcribing the book on this device — the default path (~85x realtime measured
    /// here, vs 4.5x on the host). Explicit user action only.
    func startDeviceTranscription() {
      guard #available(iOS 26.0, *), duration > 0, let store, deviceSessionBox == nil else {
        return
      }
      // The model's provider/remote carry the ABS-token authorization; the session must inherit
      // them, or its very first tunnel request dies on a 401. (Verified the hard way before the
      // seams existed: defaults constructed unauthorized clients and the run failed silently.)
      let session = DeviceTranscriptionSession(
        itemID: itemID,
        duration: duration,
        store: store,
        audio: audioProvider,
        remote: remote,
        // When the item has an epub, its text becomes the transcript (ASR supplies only the
        // timing scaffold) — the book's own prose is the default wherever one exists.
        ebookText: { [itemID] in await EbookTranscriptText.text(forItem: itemID) }
      )
      deviceSessionBox = session
      session.start()
      mirrorDeviceSession()
    }

    func cancelDeviceTranscription() {
      guard #available(iOS 26.0, *),
        let session = deviceSessionBox as? DeviceTranscriptionSession
      else { return }
      session.cancel()
      mirrorDeviceSession()
    }

    /// Clear the finished/failed status line (tap-to-dismiss on the banner).
    func acknowledgeDeviceStatus() {
      guard #available(iOS 26.0, *),
        let session = deviceSessionBox as? DeviceTranscriptionSession, !session.isActive
      else { return }
      deviceSessionBox = nil
      deviceActive = false
      deviceStatusText = nil
    }

    private func mirrorDeviceSession() {
      guard #available(iOS 26.0, *),
        let session = deviceSessionBox as? DeviceTranscriptionSession
      else { return }
      deviceActive = session.isActive
      deviceFraction = session.fraction
      deviceRate = session.effectiveRate
      deviceTrack = (session.currentTrack, session.totalTracks)
      let onDevice =
        session.usedEbookText
        ? String(localized: "Transcript uses the book's text")
        : String(localized: "Transcribed on iPhone")
      deviceStatusText =
        switch session.phase {
        case .idle: nil
        case .preparing: String(localized: "Preparing…")
        case .running:
          String(
            localized:
              "Transcribing on iPhone — \(Int(session.fraction * 100))% · track \(session.currentTrack)/\(session.totalTracks)"
          )
        case .aligning: String(localized: "Matching the book's text…")
        case .uploading: String(localized: "Saving to server…")
        case .finished(true): String(localized: "\(onDevice) — saved to server ✓")
        case .finished(false): String(localized: "\(onDevice) — server already had one")
        case .finished(nil): onDevice
        case .cancelled: String(localized: "Transcription cancelled — progress kept")
        case .failed(let reason): String(localized: "Transcription failed: \(reason)")
        }
    }
    #else
    func startDeviceTranscription() {}
    func cancelDeviceTranscription() {}
    func acknowledgeDeviceStatus() {}
    private func mirrorDeviceSession() {}
    #endif

    // MARK: - LLM cleanup

    /// Clean the book's raw-ASR chunks with the on-device model, playhead-first. Explicit user
    /// action, or auto-started once per presentation by the "Clean Up Transcripts" preference.
    func startCleanup() {
      guard #available(iOS 26.0, *), cleanupSupported, duration > 0, let store,
        cleanupSessionBox == nil
      else { return }
      let session = CleanupSession(
        itemID: itemID,
        duration: duration,
        bookContext: bookContext,
        store: store,
        remote: remote,
        // Each committed chunk should reach the screen immediately — drop the loaded window so
        // the next maintenance pass re-reads the store, where the cleaned tier now wins.
        onChunkCleaned: { [weak self] in
          self?.window = nil
          self?.kick()
        }
      )
      cleanupSessionBox = session
      session.start(from: position)
      mirrorCleanupSession()
    }

    func cancelCleanup() {
      guard #available(iOS 26.0, *),
        let session = cleanupSessionBox as? CleanupSession
      else { return }
      session.cancel()
      mirrorCleanupSession()
    }

    /// Clear the finished/failed cleanup line (tap-to-dismiss on the banner).
    func acknowledgeCleanupStatus() {
      guard #available(iOS 26.0, *),
        let session = cleanupSessionBox as? CleanupSession,
        session.phase != .running, session.phase != .uploading
      else { return }
      cleanupSessionBox = nil
      cleanupActive = false
      cleanupStatusText = nil
      refreshCleanupEligibility()
    }

    private func mirrorCleanupSession() {
      guard #available(iOS 26.0, *),
        let session = cleanupSessionBox as? CleanupSession
      else { return }
      cleanupActive = session.phase == .running || session.phase == .uploading
      cleanupFraction = session.fraction
      cleanupStatusText = session.statusText
    }

    /// Recompute whether cleanup has anything to do, and auto-start it if the preference asks.
    /// Row-metadata read only — no blob decodes — so this is cheap enough for its call sites
    /// (sheet open, chunk commits, status acknowledgement).
    private func refreshCleanupEligibility() {
      guard #available(iOS 26.0, *), cleanupSupported, let store else {
        cleanupHasRawText = false
        return
      }
      Task { [weak self, itemID] in
        let tiers = (try? await store.chunkProvenances(forItem: itemID)) ?? [:]
        let hasRaw = tiers.contains { $0.value.quality <= TranscriptProvenance.hostRaw.quality }
        guard let self else { return }
        self.cleanupHasRawText = hasRaw
        if hasRaw, self.state == .ready,
          UserPreferences.shared.transcriptCleanupWhileListening,
          self.cleanupSessionBox == nil,
          TranscriptionJobManager.shared.claimCleanupAutoStart(for: itemID)
        {
          self.startCleanup()
        }
      }
    }

    func stop() {
      active = false
      ticker?.cancel()
      ticker = nil
      maintainer?.cancel()
      maintainer = nil
    }

    func seek(to time: TimeInterval) {
      onSeek(time)
      position = clamped(time)
      pendingBrowseRowID = nil
      window = nil
      updateActiveLine()
      updateCurrentChapter()
      kick()
    }

    // MARK: - Chapters

    var currentChapterTitle: String? {
      currentChapterIndex.map { chapters[$0].title }
    }

    /// Chapter selection from the title dropdown — a *browse*, never a seek. The transcript jumps
    /// to the chapter while the playhead stays where it is; tapping a line remains the only thing
    /// that moves playback. Re-selecting the chapter that's playing means "take me back": resume
    /// tracking the playhead, don't restart the chapter.
    func browseToChapter(_ marker: ChapterMarker) {
      if let index = currentChapterIndex, chapters[index].id == marker.id {
        follow = true
        // Publish directly: when the active row is already loaded, `activeRowID` never changes,
        // so the follow scroll wouldn't fire. When it isn't, this is nil and the recentred
        // window re-derives `activeRowID`, which scrolls on its own.
        browseScrollRowID = activeRowID
        return
      }
      follow = false
      // The window starts a chunk before the boundary: `rebuildRows` only emits a header for a
      // boundary strictly inside the loaded slice, and the header is the scroll target.
      let start = clamped(marker.start)
      window = max(0, start - TranscriptGrid.span)...min(duration, start + Self.windowAhead)
      pendingBrowseRowID = "chapter-\(marker.id)"
      kick()
    }

    func browseScrollHandled() {
      browseScrollRowID = nil
    }

    /// The pill's action: resume tracking and recenter the window on the playhead. The view scrolls
    /// to `activeRowID` itself, since scrolling needs the ScrollViewReader proxy.
    func returnToPlayhead() {
      follow = true
    }

    private func updateCurrentChapter() {
      guard !chapters.isEmpty else { return }
      var low = 0
      var high = chapters.count - 1
      var found: Int?
      while low <= high {
        let mid = (low + high) / 2
        if chapters[mid].start <= position {
          found = mid
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      if found != currentChapterIndex {
        currentChapterIndex = found
      }
    }

    /// Interleave chapter headers at boundaries that fall between consecutive loaded segments. A
    /// chapter that began before the window gets no mid-window header — the nav title already names
    /// it — so the cursor starts at the first boundary past the first line.
    private func rebuildRows() {
      guard !segments.isEmpty else {
        rows = []
        return
      }
      var built: [Row] = []
      built.reserveCapacity(segments.count + 8)
      var cursor = chapters.firstIndex { $0.start > segments[0].start } ?? chapters.count

      for (index, segment) in segments.enumerated() {
        while cursor < chapters.count, chapters[cursor].start <= segment.start {
          built.append(.chapter(chapters[cursor]))
          cursor += 1
        }
        built.append(.line(index: index, segment: segment))
      }
      rows = built
    }

    /// Extend the loaded window backward — the reader reaching for earlier text. No-op while
    /// following, where the top row's appearance is a layout artifact, not intent.
    func pageBackward() {
      guard !follow, let current = window, current.lowerBound > 0 else { return }
      window = max(0, current.lowerBound - 2 * TranscriptGrid.span)...current.upperBound
      kick()
    }

    func pageForward() {
      guard !follow, let current = window, current.upperBound < duration else { return }
      window = current.lowerBound...min(duration, current.upperBound + 2 * TranscriptGrid.span)
      kick()
    }

    // FORK-BEGIN(server-jobs)
    #if SPEAKER_STACK
    /// The job-capable view of the remote, when it has one. Nil on remotes without server-side
    /// transcription (and in server-less builds) — the whole job UI keys off this being present.
    private var jobService: (any RemoteTranscriptionJobService)? {
      guard CompanionSettings.supports(.jobs) else { return nil }
      return remote as? any RemoteTranscriptionJobService
    }

    /// Whether this server has a worker to ask; the request panel offers the button on this.
    var canTranscribeOnServer: Bool { jobService != nil }

    /// Start (or resume) transcription on the host. Explicit user action only — this burns hours of
    /// CPU on the server, so nothing in the maintenance loop is allowed to call it.
    func requestServerTranscription() {
      guard duration > 0, let jobService else { return }
      jobActionFailed = false
      Task {
        do {
          let job = try await jobService.requestTranscription(forItem: itemID)
          let coverage =
            worker?.coverage ?? RemoteCoverage(hasTranscript: false, segments: 0, coveredSecs: 0)
          worker = WorkerStatus(coverage: coverage, job: job)
          // Coverage is about to start moving; let imports retry as it does.
          stalledWindow = nil
        } catch {
          jobActionFailed = true
        }
      }
    }

    func cancelServerTranscription() {
      guard let job = worker?.job, job.isActive, let jobService else { return }
      jobActionFailed = false
      Task {
        do {
          try await jobService.cancelJob(id: job.id)
          await refreshWorkerStatus(force: true)
        } catch {
          jobActionFailed = true
        }
      }
    }
    #endif
    // FORK-END(server-jobs)

    private func startLoops() {
      ticker?.cancel()
      ticker = Task { [weak self] in
        var tick = 0
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.tickInterval)
          guard let self, self.active else { return }
          self.samplePlayhead()
          // The banner mirrors keep the old 200ms cadence: they re-render chrome, and nothing
          // about them needs frame precision.
          tick += 1
          if tick.isMultiple(of: Self.mirrorEveryNTicks) {
            self.mirrorDeviceSession()
            self.mirrorCleanupSession()
          }
        }
      }

      maintainer?.cancel()
      maintainer = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.maintenanceInterval)
          guard let self, self.active else { return }
          await self.maintainNow()
        }
      }
    }

    /// One playhead read. `position` carries a small lead so a word lights as it's heard, not a
    /// frame or two after: the sample is up to one tick old by the time the frame it drives is on
    /// glass, and SwiftUI's commit adds about a frame on top. Assigned only on change — a paused
    /// playhead then costs no re-render at the tick rate.
    private func samplePlayhead() {
      let sampled = clamped(positionProvider() + Self.highlightLead)
      guard sampled != position else { return }
      position = sampled
      updateActiveLine()
      updateCurrentChapter()
    }

    private func kick() {
      Task { await maintainNow() }
    }

    /// One maintenance pass: ensure the window's transcript is local, load it, and keep the worker
    /// status fresh while anything is still missing.
    private func maintainNow() async {
      guard active, !maintaining, let store else { return }
      maintaining = true
      defer { maintaining = false }

      if follow || window == nil {
        let pos = position
        // Hysteresis: re-centre only when the playhead nears an edge. Sliding the window every
        // pass dropped a row off the top every couple of seconds — each one a content shift the
        // teleprompter had to compensate, and when one landed mid-glide it showed as a snap.
        let keep =
          follow
          && window.map { current in
            (current.lowerBound <= 0 || pos - current.lowerBound >= Self.windowBehind / 2)
              && (current.upperBound >= duration || current.upperBound - pos >= Self.windowAhead / 2)
              && current.contains(pos)
          } == true
        if !keep {
          window = max(0, pos - Self.windowBehind)...max(min(duration, pos + Self.windowAhead), 1)
        }
      }
      guard let window else { return }

      do {
        var coverage = try await store.coverage(forItem: itemID)
        var missing = coverage.missingChunks(in: window)

        if !missing.isEmpty, let remoteSource = remote?.source, shouldAttemptImport(for: window) {
          var committed = 0
          do {
            for try await chunk in remoteSource.chunks(forItem: itemID, indices: missing) {
              try await store.commit(chunk)
              committed += 1
            }
          } catch is TranscriptionError {
            // .noTranscript and friends — nothing importable right now; fall through to the stall.
          }
          coverage = try await store.coverage(forItem: itemID)
          missing = coverage.missingChunks(in: window)

          if committed == 0 {
            stalledWindow = window
            stalledCoveredSecs = worker?.coverage.coveredSecs ?? -1
          } else {
            stalledWindow = nil
          }
        }

        let stored = try await store.segments(forItem: itemID, in: window)
        let loaded = displayPieceLimit.map { Self.pieces(of: stored, limit: $0) } ?? stored
        if loaded != segments {
          segments = loaded
          rebuildRows()
        }
        if loaded.isEmpty {
          state = .missingTranscript
        } else {
          state = .ready
          updateActiveLine()
        }

        // A browse target resolves as soon as its header row exists — usually this pass, but for
        // a still-transcribing span it can be a later one, finishing the jump when text arrives.
        if let pending = pendingBrowseRowID, rows.contains(where: { $0.id == pending }) {
          pendingBrowseRowID = nil
          browseScrollRowID = pending
        }

        // Keep the worker's view fresh whenever there is anything left to want from it: the missing
        // panel needs coverage/job data, and an active job's progress drives both the UI and the
        // stall release above.
        if state == .missingTranscript || !missing.isEmpty || worker?.job?.isActive == true {
          await refreshWorkerStatus(force: false)
        }
      } catch {
        if segments.isEmpty {
          state = .missingTranscript
        }
      }
    }

    private static func pieces(of segments: [TranscriptSegment], limit: Int) -> [TranscriptSegment] {
      segments.flatMap { segment in
        segment.displayPieces(maxCharacters: limit).prefix(64).enumerated().map { index, piece in
          TranscriptSegment(
            seg: segment.seg * 64 + index,
            track: piece.track,
            start: piece.start,
            end: piece.end,
            text: piece.text,
            words: piece.words
          )
        }
      }
    }

    private func shouldAttemptImport(for window: ClosedRange<TimeInterval>) -> Bool {
      guard let stalledWindow else { return true }
      if window != stalledWindow { return true }
      return (worker?.coverage.coveredSecs ?? -1) > stalledCoveredSecs
    }

    // FORK-BEGIN(server-jobs)
    #if SPEAKER_STACK
    private func refreshWorkerStatus(force: Bool) async {
      guard let jobService else { return }
      let now = Date()
      guard force || now.timeIntervalSince(lastWorkerPoll) >= Self.workerPollInterval else { return }
      lastWorkerPoll = now
      if let status = try? await jobService.status(forItem: itemID) {
        worker = status
      }
    }
    #else
    private func refreshWorkerStatus(force: Bool) async {}
    #endif
    // FORK-END(server-jobs)

    /// Progress data can outrun a book's nominal duration (edition mismatches are real); clamping
    /// keeps the window range constructible instead of trapping.
    private func clamped(_ time: TimeInterval) -> TimeInterval {
      min(max(0, time), max(0, duration))
    }

    /// The active line is the last segment starting at or before the playhead — binary search, same as
    /// the reference player. Segments are contiguous but ASR stamps drift, so "last start <= pos" keeps
    /// a line lit across gaps instead of blanking between segments.
    private func updateActiveLine() {
      guard !segments.isEmpty else {
        activeIndex = -1
        activeSegmentID = nil
        return
      }
      var low = 0
      var high = segments.count - 1
      var found = -1
      while low <= high {
        let mid = (low + high) / 2
        if segments[mid].start <= position {
          found = mid
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      // When the user has paged far from the playhead, the playhead can fall wholly outside the
      // loaded slice; the last loaded line is then merely nearest, not active.
      if found == segments.count - 1, let last = segments.last, position > last.end + 30 {
        found = -1
      }
      if found != activeIndex {
        activeIndex = found
        activeSegmentID = found >= 0 ? segments[found].seg : nil
        activeRowID = activeSegmentID.map { "seg-\($0)" }
      }
    }
  }
}
