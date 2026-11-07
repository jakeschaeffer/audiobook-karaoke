import Snips
import SwiftUI

/// What appears right after a tap: the text that was just saved, with Note and Undo. It leaves on
/// its own after a few seconds; nothing here blocks listening.
struct SnipCaptureCard: View {
  let snip: Snip
  var bridge = SnipAppBridge.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "highlighter")
        Text("Snipped", tableName: "Snips")
          .fontWeight(.semibold)
        Spacer()
        Text(SnipFormatting.span(snip))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .font(.subheadline)

      if let excerpt = snip.excerpt {
        Text(excerpt)
          .font(.callout)
          .lineLimit(3)
      } else {
        Text("No transcript here yet. The text fills in once it is.", tableName: "Snips")
          .font(.callout)
          .italic()
          .foregroundStyle(.secondary)
      }

      HStack {
        Button(action: {
          bridge.dismissCard()
          bridge.edit(snip, focusingNote: true)
        }) {
          Label {
            Text("Add note", tableName: "Snips")
          } icon: {
            Image(systemName: "note.text.badge.plus")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Spacer()

        Button(action: { Task { await bridge.undoLastCapture() } }) {
          Text("Undo", tableName: "Snips")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button(action: { bridge.dismissCard() }) {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(Text("Dismiss", tableName: "Snips"))
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
  }
}
