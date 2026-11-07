import Snips
import SwiftUI

/// One snip in a list: the text itself, the note beneath it, where it sits in the book.
struct SnipRow: View {
  let snip: Snip

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let excerpt = snip.excerpt {
        Text(excerpt)
          .font(.body)
          .lineLimit(4)
      } else {
        Text("No transcript for this stretch yet", tableName: "Snips")
          .font(.body)
          .italic()
          .foregroundStyle(.secondary)
      }

      if let note = snip.note, !note.isEmpty {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "note.text")
            .font(.caption)
            .padding(.top, 2)
          Text(note)
            .font(.subheadline)
        }
        .foregroundStyle(Color.accentColor)
      }

      HStack(spacing: 8) {
        Text(SnipFormatting.span(snip))
          .monospacedDigit()
        Text("·")
        Text(snip.capturedAt, format: .relative(presentation: .named))
        if snip.captureOutput == .bookmark {
          Text("·")
          Text("from a bookmark", tableName: "Snips")
        }
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, 4)
  }
}
