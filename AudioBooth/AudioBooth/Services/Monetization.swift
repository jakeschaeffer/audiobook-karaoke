/// Monetization switches for this fork.
///
/// Upstream ships a RevenueCat-backed tip jar under its own account; the fork removed that key
/// (it isn't ours to bill against). Everything tip-jar-shaped keys off this one constant:
/// empty = RevenueCat never configures and the Settings section stays hidden, in both the
/// personal and the store build. Drop in your own key to bring it back.
enum Monetization {
  static let revenueCatAPIKey = ""
}
