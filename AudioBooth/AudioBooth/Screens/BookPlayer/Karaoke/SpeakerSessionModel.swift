import API
import Foundation
import Models
import SwiftUI
import Transcription

// The personal build’s daemon-driven speaker stack; the store build compiles it out
// wholesale (see FORK-NOTES “The two builds”).
#if SPEAKER_STACK

/// A WiiM playback session, driven entirely through the abs-session daemon.
///
/// Never the speaker directly: the daemon owns the ABS session and progress sync, and publishes
/// every state change to Home Assistant (MQTT, retained + discovery) and to WS listeners — so
/// commanding it is what keeps this app, HA dashboards, and the speaker in one story. The WS is the
/// other half of that handoff: a pause from an HA dashboard lands here within a second and flips the
/// transport bar, no polling.
///
/// Position between the daemon's 1s ticks is interpolated from the last tick's wall-clock, which is
/// what lets the karaoke word highlight run at its 200ms cadence against a speaker in another room.
@MainActor
@Observable
final class SpeakerSessionModel {
  private(set) var remote: RemotePlaybackState?
  private(set) var actionFailed = false
  /// Volume slider binding, 0–100. Seeded from the daemon whenever it polled the device.
  var volume: Double = 20

  let itemID: String
  /// Set by `SpeakerSessionManager` — fired on every transition of `hasOwnSession`, i.e. when the
  /// daemon's session for this book appears (true) or ends (false), *however* that happens: our
  /// own stop, a Home Assistant stop, or another book taking the speaker. This is what lets the
  /// manager release a session it would otherwise track forever.
  var onOwnSessionChanged: ((Bool) -> Void)?
  /// Number of sheets currently presenting this session's transport. Maintained by
  /// `SpeakerSessionManager.sheetAttached/sheetDismissed`; an ended session keeps its monitor
  /// alive while a sheet still shows it (the transport needs live state to offer a restart).
  var attachedSheets = 0
  private var hadOwnSession = false
  private let autoStart: Bool
  private let transport: DaemonTransportClient
  private let events: DaemonEventsSocket
  private let onContinueOnPhone: (TimeInterval) -> Void
  private var monitor: Task<Void, Never>?

  private var basePosition: TimeInterval
  private var baseDate = Date()
  private var advancing = false

  init(
    itemID: String,
    startPosition: TimeInterval,
    autoStart: Bool,
    onContinueOnPhone: @escaping (TimeInterval) -> Void
  ) {
    self.itemID = itemID
    self.autoStart = autoStart
    self.onContinueOnPhone = onContinueOnPhone
    basePosition = startPosition

    let authorization: AuthorizationProvider = {
      guard let server = await Audiobookshelf.shared.authentication.server else { return nil }
      return try? await server.freshToken.bearer
    }
    transport = DaemonTransportClient(endpoint: .current, authorization: authorization)
    events = DaemonEventsSocket(endpoint: .current, authorization: authorization)
  }

  /// Book-absolute playhead: the last daemon tick, advanced by wall-clock while playing.
  var currentPosition: TimeInterval {
    advancing ? basePosition + Date().timeIntervalSince(baseDate) : basePosition
  }

  /// Whether the speaker currently has a session for *this* book. When the daemon is playing a
  /// different item, its ticks must not drive this book's karaoke, and "play" means replacing that
  /// session — worth saying in the UI, not silently doing.
  var hasOwnSession: Bool {
    remote?.hasSession == true && remote?.itemID == itemID
  }

  var isForeignSession: Bool {
    remote?.hasSession == true && remote?.itemID != itemID
  }

  var isPlaying: Bool {
    hasOwnSession && remote?.isPlaying == true
  }

  func activate() async {
    startMonitor()
    // Skip autoplay when the speaker is already running this book — a reused session (the sheet
    // was closed and reopened) must rejoin the live playback, not re-seek it to "now", which
    // stutters, or worse, replay from a stale position.
    if autoStart, !hasOwnSession {
      await startPlayback()
    }
  }

  func deactivate() {
    monitor?.cancel()
    monitor = nil
    // The session keeps playing on the speaker — dismissing the sheet is walking away from the
    // controls, not stopping the book. /stop is an explicit action.
  }

  /// Backgrounding pauses the WS (sockets don't survive suspension anyway); resuming reconnects,
  /// and the daemon's connect-time snapshot re-syncs state — including an end we slept through,
  /// which fires the ownership transition on arrival.
  func suspendMonitor() {
    monitor?.cancel()
    monitor = nil
  }

  func resumeMonitor() {
    guard monitor == nil else { return }
    startMonitor()
  }

  /// Seed state from a one-shot `/status` reply (session discovery), so the surfaces that key off
  /// `hasOwnSession` light up immediately instead of waiting for the first WS frame.
  func adopt(_ state: RemotePlaybackState) {
    apply(state)
  }

  /// Start (or take over) speaker playback of this book at the current playhead.
  func startPlayback() async {
    await run { [self] in try await transport.play(itemID: itemID, position: currentPosition) }
  }

  func togglePlayback() {
    Task {
      if hasOwnSession {
        await run { [self] in try await transport.toggle() }
      } else {
        await startPlayback()
      }
    }
  }

  func skip(_ delta: TimeInterval) {
    Task { await run { [self] in try await transport.seek(delta: delta) } }
  }

  /// Tap-a-line seek from the karaoke view. While idle, a seek *is* starting playback there — same
  /// semantics as the reference player.
  func seek(to position: TimeInterval) {
    Task {
      if hasOwnSession {
        await run { [self] in try await transport.seek(position: position) }
      } else {
        await run { [self] in try await transport.play(itemID: itemID, position: position) }
      }
    }
  }

  func commitVolume() {
    Task { await run { [self] in try await transport.setVolume(Int(volume)) } }
  }

  /// Pause the speaker and hand playback to the phone at the speaker's position.
  ///
  /// The pause must succeed first: if the daemon is unreachable, starting the phone anyway means
  /// two rooms playing at once with no feedback — the failure surfaces on `actionFailed` (the
  /// transport bar's error line) and the handoff simply doesn't happen. The daemon session
  /// survives as paused; surfaces follow the phone because the manager's `activeSession` yields
  /// to live local playback.
  func continueOnPhone() {
    Task {
      let position = currentPosition
      await run { [self] in try await transport.pause() }
      guard !actionFailed else { return }
      onContinueOnPhone(position)
    }
  }

  func stopSpeaker() {
    // No explicit end-hook: the stop response applies as idle, and the ownership transition in
    // `apply` fires from that — the same path an external (Home Assistant) stop takes.
    Task { await run { [self] in try await transport.stop() } }
  }

  private func startMonitor() {
    // The transcript sheet always carries a session; with no speaker there is nothing to listen to.
    guard CompanionSettings.supports(.speaker) else { return }
    monitor?.cancel()
    monitor = Task { [weak self] in
      guard let self else { return }
      for await state in self.events.states() {
        if Task.isCancelled { return }
        self.apply(state)
      }
    }
  }

  private func apply(_ state: RemotePlaybackState) {
    let wasAdvancing = advancing
    let livePosition = currentPosition
    remote = state
    if state.itemID == itemID, let position = state.position {
      basePosition = position
      baseDate = Date()
    }
    advancing = state.isPlaying && state.itemID == itemID
    if let deviceVolume = state.volume {
      volume = Double(deviceVolume)
    }

    // Double-audio guard. The daemon says the room is playing this book while the phone is also
    // audibly playing it. Every deliberate in-app local start pauses or transfers the speaker
    // first, so this state means an out-of-band local start (lock screen, AirPods, CarPlay — all
    // speaker-blind by design) or an external resume over live local playback. One deterministic
    // winner: the room keeps playing, the phone yields. The daemon ticks every second while
    // playing, so in the foreground this heals within a tick; a locked phone can't be helped
    // until unlock (the monitor is suspended), where the reconnect snapshot lands here.
    if advancing, let local = PlayerManager.shared.current, local.id == itemID, local.isPlaying {
      PlayerManager.shared.pause()
    }

    // The speaker just stopped moving (pause, stop, or another book took it): fold its live
    // position into local saved progress *now*, freshly timestamped. The daemon's own pushes to
    // ABS run on a lag, so anything that later starts local playback from saved progress — the
    // big play button, the lock screen, "Play on iPhone" — would otherwise open up to that lag
    // behind the room; and because the daemon's copy carries a *newer* timestamp than the
    // phone's last own write, newer-wins sync can't save you. This write is both freshest and
    // truest, so it beats the daemon's final stale push in both directions. Local only — no
    // network, no delay; the regular session sync forwards it to ABS.
    if wasAdvancing, !advancing {
      persistProgress(at: state.itemID == itemID ? (state.position ?? livePosition) : livePosition)
    }

    // Ownership transitions, from whatever source the state arrived (WS frame, transport
    // response, discovery snapshot). Without this, a session stopped from Home Assistant stayed
    // tracked forever: the WS reconnected for the rest of the launch and — because discovery
    // guards on "nothing tracked" — no new session could ever be adopted again.
    let owns = hasOwnSession
    if owns != hadOwnSession {
      hadOwnSession = owns
      onOwnSessionChanged?(owns)
    }
  }

  /// Write the speaker's playhead into this book's local `MediaProgress`. Skipped while the
  /// phone itself is mid-playback of the same book — the live player owns its position and a
  /// background write would fight its own ticker for no benefit.
  private func persistProgress(at position: TimeInterval) {
    let player = PlayerManager.shared
    if player.current?.id == itemID, player.current?.isPlaying == true { return }
    let duration = remote?.duration ?? (try? MediaProgress.fetch(bookID: itemID))?.duration ?? 0
    guard duration > 0 else { return }
    try? MediaProgress.updateProgress(
      for: itemID,
      currentTime: position,
      duration: duration,
      progress: min(position / duration, 1)
    )
  }

  private func run(_ action: () async throws -> RemotePlaybackState) async {
    actionFailed = false
    do {
      apply(try await action())
    } catch {
      actionFailed = true
      // The sheets surface `actionFailed` inline; the chooser, the pill, and the menu have no
      // error surface of their own and used to fail silently — the phone paused, nothing
      // played, no explanation. One toast, only when no sheet is already saying it.
      if attachedSheets == 0 {
        Toast(error: String(localized: "Couldn't reach the speaker controller.")).show()
      }
    }
  }
}
#endif
