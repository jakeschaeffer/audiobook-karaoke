#if os(iOS)
import UIKit

/// The one owner of `UIApplication.isIdleTimerDisabled`.
///
/// Three parties legitimately want the screen awake — the player's keep-awake preference, a
/// running transcription, a running cleanup — and each used to write the flag directly, so
/// whichever finished first re-enabled sleep out from under the others: a cleanup completing
/// stole the player's keep-awake; a player closing let the screen sleep mid-transcription,
/// which silently stops the run (there is no background compute). Last-writer-wins is the whole
/// bug class; this replaces it with a hold count plus a base bit.
///
/// `setBaseKeepAwake` is the player preference (one bit, set/cleared by the player's lifecycle);
/// `acquire`/`release` are for work that must not be interrupted, keyed by token so a double
/// release of one holder can't release another's hold.
@MainActor
public final class ScreenWakeCoordinator {
  public static let shared = ScreenWakeCoordinator()

  private var holders = Set<String>()
  private var baseKeepAwake = false

  private init() {}

  public func acquire(_ token: String) {
    holders.insert(token)
    apply()
  }

  public func release(_ token: String) {
    holders.remove(token)
    apply()
  }

  /// The player's keep-awake preference while the player is visible. Not a hold: it flips with
  /// the preference and the player's appearance, independent of any running work.
  public func setBaseKeepAwake(_ keepAwake: Bool) {
    baseKeepAwake = keepAwake
    apply()
  }

  private func apply() {
    UIApplication.shared.isIdleTimerDisabled = baseKeepAwake || !holders.isEmpty
  }
}
#endif
