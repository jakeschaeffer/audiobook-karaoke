import Snips
import SwiftUI

/// The player's bottom-bar Snip control: one tap takes a snip of what is playing.
struct SnipControlButton: View {
  var body: some View {
    Button(action: {
      Haptics.impact(.medium)
      Task { await SnipAppBridge.shared.capture() }
    }) {
      VStack(spacing: 6) {
        Image(systemName: PlayerControl.snip.systemImage)
          .font(.system(size: 20))
          .frame(width: 20, height: 20)
        Text(PlayerControl.snip.displayName)
          .font(.caption2)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityHint(Text("Saves the last stretch you heard, with its text", tableName: "Snips"))
  }
}
