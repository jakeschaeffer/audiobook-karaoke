import API
import Foundation
import Models
import Transcription

// The personal build’s daemon-driven speaker stack; the store build compiles it out
// wholesale (see FORK-NOTES “The two builds”).
#if SPEAKER_STACK

/// Phone-side owner of the speaker session, so it survives the sheet that spawned it.
///
/// The session used to live inside the speaker sheet's `.sheet` closure. Dismissing the sheet
/// orphaned it: the speaker kept playing (deliberately — `deactivate()` is "walking away from the
/// controls, not stopping the book") but the phone stopped listening, so the player and the karaoke
/// cover fell back to stale local `MediaProgress` and looked paused, and reopening the sheet built a
/// *new* session seeded from that stale position — audibly rewinding the speaker.
///
/// Ownership fixes all three at once: while the speaker has a session for a book, the model (and its
/// WS monitor) stays alive here, every transcript surface can read the live playhead through
/// `livePosition(for:)`, and reopening the sheet reuses the session instead of re-seeding it.
@MainActor
@Observable
final class SpeakerSessionManager {
  static let shared = SpeakerSessionManager()

  private(set) var current: SpeakerSessionModel?

  private init() {}

  /// The session for `itemID`, reusing a live one — reuse is what makes "Return to Speaker" a
  /// no-op on the speaker instead of a seek. `startPosition`/`autoStart` only apply on creation;
  /// an existing session already knows where the speaker is.
  func session(
    for itemID: String,
    startPosition: @autoclosure () -> TimeInterval,
    autoStart: Bool,
    onContinueOnPhone: @escaping (TimeInterval) -> Void
  ) -> SpeakerSessionModel {
    if let current, current.itemID == itemID {
      return current
    }
    // One speaker, one session: starting a different book replaces the old session outright.
    current?.deactivate()
    let session = SpeakerSessionModel(
      itemID: itemID,
      startPosition: startPosition(),
      autoStart: autoStart,
      onContinueOnPhone: onContinueOnPhone
    )
    adopt(session)
    return session
  }

  /// One-shot discovery of a session that already exists daemon-side — the Home Assistant flow:
  /// playback starts from an HA dashboard, then the phone opens mid-book wanting the playhead.
  /// Queries the transport's `/status`; if the speaker is running (or paused in) a book and nothing
  /// is tracked yet, adopt it — seeded from the reply so the pill and cover light up immediately,
  /// then live via the WS monitor. Never autoplays: it's the daemon's session, we're tuning in.
  /// Cheap and idempotent; called on app activation and player appearance.
  func discoverExistingSession() {
    guard current == nil, !discovering, CompanionSettings.supports(.speaker) else { return }
    guard Audiobookshelf.shared.authentication.isAuthenticated else { return }
    discovering = true
    Task { [weak self] in
      defer { self?.discovering = false }
      let authorization: AuthorizationProvider = {
        guard let server = await Audiobookshelf.shared.authentication.server else { return nil }
        return try? await server.freshToken.bearer
      }
      let transport = DaemonTransportClient(endpoint: .current, authorization: authorization)
      // Unreachable daemon or no session both mean "nothing to adopt" — silence, not an error.
      guard let state = try? await transport.status(),
        state.hasSession, let itemID = state.itemID,
        let self, self.current == nil
      else { return }

      let session = SpeakerSessionModel(
        itemID: itemID,
        startPosition: state.position ?? 0,
        autoStart: false,
        onContinueOnPhone: { position in
          Self.handoffToPhone(itemID: itemID, position: position, duration: state.duration)
        }
      )
      session.adopt(state)
      self.adopt(session)
      await session.activate()
    }
  }

  private var discovering = false

  /// Re-read the daemon's state into the tracked session, once. For moments when the extrapolated
  /// position may be stale: after the app slept with the monitor suspended, the speaker may have
  /// been paused or moved from Home Assistant in between, and a snip taken from the Action Button
  /// must not land where the phone *guessed* the room was. Silent when unreachable: the session's
  /// own estimate stands.
  func refreshFromDaemon() async {
    guard let current, CompanionSettings.supports(.speaker) else { return }
    let authorization: AuthorizationProvider = {
      guard let server = await Audiobookshelf.shared.authentication.server else { return nil }
      return try? await server.freshToken.bearer
    }
    let transport = DaemonTransportClient(endpoint: .current, authorization: authorization)
    guard let state = try? await transport.status() else { return }
    current.adopt(state)
  }

  private func adopt(_ session: SpeakerSessionModel) {
    session.onOwnSessionChanged = { [weak self, weak session] owns in
      guard let self, let session else { return }
      if owns {
        // A session (re)claimed the speaker — e.g. play tapped from a sheet after an external
        // stop. One speaker, one tracked session.
        if self.current !== session {
          self.current?.deactivate()
          self.current = session
        }
      } else {
        // Ended (our stop, an HA stop, or another book took the speaker): stop tracking so
        // discovery can adopt whatever comes next. Keep the monitor only while a sheet still
        // shows this transport — it needs live state to offer a restart; dismissal reaps it.
        guard self.current === session else { return }
        self.current = nil
        if session.attachedSheets == 0 {
          session.deactivate()
        }
        // "Another book took the speaker" is an end *and* a beginning — re-discover now
        // instead of waiting for the next app activation, or the new session stays invisible
        // until the app is backgrounded and reopened. Idempotent and self-guarding.
        self.discoverExistingSession()
      }
    }
    current = session
  }

  /// The server changed or was removed: the tracked session belongs to the old one. Local playback
  /// never knew about it, and whatever the old speaker is doing is that server's business.
  func companionRemoved() {
    current?.deactivate()
    current = nil
  }

  /// The app moved to the background: sockets won't survive suspension, so stop the monitor
  /// cleanly instead of letting it error-loop. `appDidBecomeActive` reconnects and re-syncs.
  func appDidEnterBackground() {
    current?.suspendMonitor()
  }

  func appDidBecomeActive() {
    current?.resumeMonitor()
    discoverExistingSession()
  }

  /// Continue-on-phone for a discovered session, which has no presenting player context: seek the
  /// live player when this book is current, else persist the position so playback opens there.
  private static func handoffToPhone(itemID: String, position: TimeInterval, duration: TimeInterval?) {
    let player = PlayerManager.shared
    if player.current?.id == itemID {
      player.current?.onSeekToTime(position)
      player.play()
      return
    }
    Task {
      let total = duration ?? (try? MediaProgress.fetch(bookID: itemID))?.duration ?? 0
      if total > 0 {
        try? MediaProgress.updateProgress(
          for: itemID,
          currentTime: position,
          duration: total,
          progress: min(position / total, 1)
        )
      }
      await player.play(itemID)
    }
  }

  /// A sheet began presenting this session's transport. Paired with `sheetDismissed`; the count
  /// is what lets an externally-ended session keep updating an open sheet without leaking once
  /// the sheet goes away.
  func sheetAttached(_ session: SpeakerSessionModel) {
    session.attachedSheets += 1
  }

  /// Sheet-dismissal policy: keep the session (and its WS monitor) while the speaker is actually
  /// playing this book; tear down idle/foreign sheets like the old behavior did — and reap
  /// orphans, i.e. sessions that ended (or were replaced) while a sheet was still showing them.
  func sheetDismissed(_ session: SpeakerSessionModel) {
    session.attachedSheets = max(0, session.attachedSheets - 1)
    guard session.attachedSheets == 0 else { return }

    if current !== session {
      session.deactivate()
    } else if !session.hasOwnSession {
      session.deactivate()
      current = nil
    }
  }

  /// The live speaker playhead for `itemID`, or nil when the speaker isn't playing that book.
  /// Transcript surfaces call this every tick, which is how they stay live after the speaker
  /// sheet closes — and how they fall back to local progress the moment the session ends.
  func livePosition(for itemID: String) -> TimeInterval? {
    activeSession(for: itemID)?.currentPosition
  }

  /// The session that merely *exists* for `itemID` — the device-chip predicate. The pill and the
  /// output chooser key off this: a paused speaker session is still a destination worth showing,
  /// even while the phone is the one playing.
  func speakerSession(for itemID: String) -> SpeakerSessionModel? {
    guard let current, current.itemID == itemID, current.hasOwnSession else { return nil }
    return current
  }

  /// Lazy last-active stamps, refreshed whenever any surface consults the predicate while an
  /// output is audibly playing. No observation machinery: every transport, pill, and ticker
  /// already calls `activeSession` continuously, which makes "which output played most recently"
  /// derivable for free — and it only has to be right at the moment both outputs sit paused.
  private var localLastPlaying = Date.distantPast
  private var speakerLastPlaying = Date.distantPast

  /// The session that should *drive transports* for `itemID` — every play button, scrubber, and
  /// transcript playhead routes through this one predicate, which is what keeps the surfaces
  /// agreeing with each other.
  func activeSession(for itemID: String) -> SpeakerSessionModel? {
    guard let session = speakerSession(for: itemID) else { return nil }
    if session.isPlaying { speakerLastPlaying = Date() }
    // Live local playback always wins — the phone is what's making sound.
    if let local = PlayerManager.shared.current, local.id == itemID {
      if local.isPlaying {
        localLastPlaying = Date()
        return nil
      }
      // Both outputs paused with the book loaded here: play should resume whichever output
      // played most recently — pausing the speaker and pressing play must stay on the speaker,
      // while a stale paused session must never start the living room by surprise. A fresh
      // launch has no stamps and falls to the phone in hand.
      if !session.isPlaying, speakerLastPlaying <= localLastPlaying { return nil }
    }
    return session
  }

}
#endif
