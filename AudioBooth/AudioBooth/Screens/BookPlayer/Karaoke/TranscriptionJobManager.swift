import Foundation

/// Process-wide owner of running on-device work — device transcription and LLM cleanup — keyed by
/// item. The `SpeakerSessionManager` pattern, applied to the other long-running sessions.
///
/// These used to live on the per-presentation `KaraokeSheet.Model`, which had two failure modes:
/// dismissing the sheet orphaned an hour-long ANE run (no UI, no cancel, screen held awake with no
/// visible reason), and reopening it — or having the karaoke cover and the sheet alive at once —
/// started a *duplicate* session against the same book's chunk rows. With the boxes here, every
/// model for a book mirrors the same run: reopened sheets show live progress and can cancel, and a
/// second start is impossible by construction.
///
/// Sessions are stored as `AnyObject` for the same reason `KaraokeSheet.Model` boxed them: the
/// concrete types are iOS-26-gated (and the transcriber doesn't link on the simulator), so this
/// type stays unconditionally compilable while callers cast behind their availability checks.
@MainActor
final class TranscriptionJobManager {
  static let shared = TranscriptionJobManager()

  private var deviceSessions: [String: AnyObject] = [:]
  private var cleanupSessions: [String: AnyObject] = [:]
  /// Books whose cleanup has auto-started this launch. The preference means "clean this book
  /// once I open its transcript", not "start again for every surface that shows it" — the cover
  /// and the sheet each build their own model, and both used to trigger.
  private var cleanupAutoStarted: Set<String> = []

  private init() {}

  func deviceSession(for itemID: String) -> AnyObject? {
    deviceSessions[itemID]
  }

  func setDeviceSession(_ session: AnyObject?, for itemID: String) {
    deviceSessions[itemID] = session
  }

  func cleanupSession(for itemID: String) -> AnyObject? {
    cleanupSessions[itemID]
  }

  func setCleanupSession(_ session: AnyObject?, for itemID: String) {
    cleanupSessions[itemID] = session
  }

  /// One auto-start per book per launch. Returns false when it already happened — callers skip.
  func claimCleanupAutoStart(for itemID: String) -> Bool {
    guard !cleanupAutoStarted.contains(itemID) else { return false }
    cleanupAutoStarted.insert(itemID)
    return true
  }
}
