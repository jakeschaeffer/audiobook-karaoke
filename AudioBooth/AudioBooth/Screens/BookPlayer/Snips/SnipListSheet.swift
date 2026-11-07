import Snips
import SwiftUI

/// A book's snips, newest first. Opening it also brings over any Audiobookshelf bookmarks for the
/// book that haven't been imported yet, and fills in text for snips taken before the transcript
/// reached them.
struct SnipListSheet: View {
  let itemID: String

  @Environment(\.dismiss) private var dismiss
  @State private var bridge = SnipAppBridge.shared
  @State private var snips: [Snip] = []
  @State private var unreadable = 0
  @State private var loaded = false

  var body: some View {
    NavigationStack {
      Group {
        if loaded && snips.isEmpty {
          ContentUnavailableView {
            Label {
              Text("No snips yet", tableName: "Snips")
            } icon: {
              Image(systemName: "highlighter")
            }
          } description: {
            Text("Tap Snip while listening to save the last stretch you heard, with its text.", tableName: "Snips")
          }
        } else {
          List {
            if unreadable > 0 {
              Label {
                Text("\(unreadable) snip file(s) couldn't be read. They were left in place.", tableName: "Snips")
                  .font(.footnote)
              } icon: {
                Image(systemName: "exclamationmark.triangle")
              }
              .foregroundStyle(.orange)
            }
            ForEach(snips) { snip in
              Button(action: { bridge.edit(snip) }) {
                SnipRow(snip: snip)
              }
              .buttonStyle(.plain)
              .swipeActions(edge: .leading) {
                playButton(snip)
                  .tint(.green)
                noteButton(snip)
                  .tint(.accentColor)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton(snip)
              }
              .contextMenu {
                noteButton(snip)
                playButton(snip)
                Divider()
                deleteButton(snip)
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle(Text("Your Snips", tableName: "Snips"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          lengthMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: { dismiss() }) {
            Label {
              Text("Close", tableName: "Snips")
            } icon: {
              Image(systemName: "xmark")
            }
          }
          .tint(.primary)
        }
      }
      .task { await load(importing: true) }
      .onChange(of: bridge.version) { Task { await load(importing: false) } }
      .sheet(
        isPresented: Binding(
          get: { bridge.editing != nil },
          set: { if !$0 { bridge.editing = nil } }
        )
      ) {
        if let snip = bridge.editing {
          SnipEditorView(snip: snip, focusNote: bridge.editingFocusesNote)
        }
      }
    }
  }

  // MARK: - Row actions (swipes and the long-press menu share them)

  /// Opens the editor with the keyboard in the note.
  private func noteButton(_ snip: Snip) -> some View {
    Button {
      bridge.edit(snip, focusingNote: true)
    } label: {
      Label {
        snip.note == nil ? Text("Add note", tableName: "Snips") : Text("Edit note", tableName: "Snips")
      } icon: {
        Image(systemName: snip.note == nil ? "note.text.badge.plus" : "note.text")
      }
    }
  }

  private func playButton(_ snip: Snip) -> some View {
    Button {
      SnipPlayback.play(snip)
      dismiss()
    } label: {
      Label {
        Text("Play", tableName: "Snips")
      } icon: {
        Image(systemName: "play.fill")
      }
    }
  }

  private func deleteButton(_ snip: Snip) -> some View {
    Button(role: .destructive) {
      Task { await bridge.delete(snip) }
    } label: {
      Label {
        Text("Delete", tableName: "Snips")
      } icon: {
        Image(systemName: "trash")
      }
    }
  }

  /// How far back the next snip reaches. Lives here rather than in Settings: it is the one knob.
  private var lengthMenu: some View {
    Menu {
      Picker(
        selection: Binding(get: { bridge.length }, set: { bridge.length = $0 }),
        label: Text("Snip length", tableName: "Snips")
      ) {
        ForEach(SnipLength.allCases) { length in
          Text(length.shortLabel).tag(length)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "ruler")
        Text(bridge.length.shortLabel)
          .monospacedDigit()
      }
      .font(.subheadline)
    }
    .accessibilityLabel(Text("Snip length", tableName: "Snips"))
  }

  private func load(importing: Bool) async {
    if importing {
      let imported = await bridge.importBookmarks(forItem: itemID)
      if imported > 0 {
        Toast(message: String(localized: "\(imported) bookmark(s) became snips", table: "Snips")).show()
      }
      await bridge.fillMissingExcerpts(forItem: itemID)
    }
    snips = await bridge.snips(forItem: itemID)
    unreadable = await bridge.unreadableCount()
    loaded = true
  }
}
