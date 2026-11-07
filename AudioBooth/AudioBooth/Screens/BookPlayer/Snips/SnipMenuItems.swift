import Snips
import SwiftUI

/// The player overflow menu's snip entries: take one, and open the book's list.
struct SnipMenuItems: View {
  let itemID: String
  /// Whether to offer the capture itself here (when the bar doesn't show the Snip control).
  var includeCapture = true
  var bridge = SnipAppBridge.shared

  var body: some View {
    if includeCapture {
      Button {
        Haptics.impact(.medium)
        Task { await bridge.capture() }
      } label: {
        Label {
          Text("Snip", tableName: "Snips")
        } icon: {
          Image(systemName: PlayerControl.snip.systemImage)
        }
      }
    }
    Button {
      bridge.listItemID = itemID
    } label: {
      Label {
        Text("Your Snips", tableName: "Snips")
      } icon: {
        Image(systemName: "highlighter")
      }
    }
  }
}
