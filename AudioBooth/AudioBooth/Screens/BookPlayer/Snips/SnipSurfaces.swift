import Snips
import SwiftUI

/// Everything snip-related the player view hosts: the card after a capture, the book's list, and
/// the editor opened from the card. One modifier, so the player's own body changes by one line.
struct SnipSurfaces: ViewModifier {
  let itemID: String
  @State private var bridge = SnipAppBridge.shared

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let snip = bridge.lastCapture, snip.itemID == itemID {
          SnipCaptureCard(snip: snip)
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.35), value: bridge.lastCapture?.id)
      .sheet(
        isPresented: Binding(
          get: { bridge.listItemID == itemID },
          set: { if !$0 { bridge.listItemID = nil } }
        )
      ) {
        SnipListSheet(itemID: itemID)
      }
      .sheet(
        isPresented: Binding(
          get: { bridge.editing != nil && bridge.listItemID == nil },
          set: { if !$0 { bridge.editing = nil } }
        )
      ) {
        if let snip = bridge.editing {
          SnipEditorView(snip: snip, focusNote: bridge.editingFocusesNote)
        }
      }
  }
}

extension View {
  func snipSurfaces(itemID: String) -> some View {
    modifier(SnipSurfaces(itemID: itemID))
  }
}
