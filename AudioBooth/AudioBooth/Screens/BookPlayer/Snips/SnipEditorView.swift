import Models
import SnipCore
import Snips
import SwiftUI
import Transcription

/// A sticky note: the book's words around the snip, with the snip's own words highlighted; tap a
/// word to move In or Out; one note, in a bar pinned above the keyboard so it is always in reach
/// however far the words scroll. Saved on Done.
///
/// Which point a tap moves: the one you chose by tapping its tile, otherwise whichever is nearer
/// to the word (the podcast player's rule). In is the point you usually fine-tune, so the hint and
/// the first tile lead with it.
struct SnipEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var bridge = SnipAppBridge.shared
  @State private var draft: Snip
  /// The point a tile pinned, or nil for "nearer point wins".
  @State private var pinned: SpanPoints.Point?
  @State private var segments: [TranscriptSegment] = []
  @State private var window: (fromMs: Int, toMs: Int)
  @State private var loading = true
  @State private var scrolledToSpan = false
  /// The note as typed. A reference the editor doesn't observe, so a keystroke redraws only the
  /// note field, not the words above it (a full redraw per keystroke reset the field mid-typing).
  @State private var note: NoteDraft

  private let original: Snip
  private let durationMs: Int
  /// Open with the keyboard in the note (the card's Add note, the list's Note action).
  private let focusNote: Bool
  private static let contextMs = 60_000

  init(snip: Snip, focusNote: Bool = false) {
    original = snip
    self.focusNote = focusNote
    _note = State(initialValue: NoteDraft(snip.note ?? ""))
    _draft = State(initialValue: snip)
    _window = State(initialValue: (max(0, snip.startMs - Self.contextMs), snip.endMs + Self.contextMs))
    let duration = (try? MediaProgress.fetch(bookID: snip.itemID))?.duration ?? 0
    durationMs = max(snip.endMs, Int((duration * 1000).rounded()))
  }

  // MARK: - Words

  struct Word: Identifiable {
    let id: Int
    let text: String
    let startMs: Int
    let endMs: Int
  }

  /// Every word in the loaded window, each with its own time (interpolated on tiers without word
  /// timings, which is close enough to tap on).
  private var words: [Word] {
    var out: [Word] = []
    for segment in segments {
      for token in segment.timedTokens() {
        let text = token.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        out.append(
          Word(
            id: out.count,
            text: text,
            startMs: Int((token.start * 1000).rounded()),
            endMs: Int((token.end * 1000).rounded())
          )
        )
      }
    }
    return out
  }

  private var span: SpanPoints.Span { .init(startMs: draft.startMs, endMs: draft.endMs) }

  private func inSpan(_ word: Word) -> Bool {
    SpanPoints.wordInSpan(startMs: word.startMs, endMs: word.endMs, span: span)
  }

  private var changed: Bool {
    draft.startMs != original.startMs || draft.endMs != original.endMs || normalizedNote != original.note
  }

  private var normalizedNote: String? {
    let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            pointTiles
            wordsSection
            actions
          }
          .padding()
          .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { SnipNoteField(note: note, focusOnAppear: focusNote) }
        .onChange(of: loading) { _, nowLoading in
          // Land on the snip's own words, not the top of the context before them.
          guard !nowLoading, !scrolledToSpan, let first = words.first(where: inSpan) else { return }
          scrolledToSpan = true
          DispatchQueue.main.async { proxy.scrollTo(first.id, anchor: .center) }
        }
      }
      .navigationTitle(Text("Snip", tableName: "Snips"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Text("Cancel", tableName: "Snips")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: { Task { await save() } }) {
            Text("Done", tableName: "Snips")
              .fontWeight(.semibold)
          }
        }
      }
      .task { await loadWindow() }
    }
  }

  private var pointTiles: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        pointTile(.in, label: Text("In", tableName: "Snips"), ms: draft.startMs)
        pointTile(.out, label: Text("Out", tableName: "Snips"), ms: draft.endMs)
        VStack(spacing: 2) {
          Text("Length", tableName: "Snips")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(SnipFormatting.length(draft.lengthMs))
            .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
      }
      Group {
        switch pinned {
        case .in: Text("Tap a word to start there.", tableName: "Snips")
        case .out: Text("Tap a word to end there.", tableName: "Snips")
        case nil: Text("Tap a word to move the nearer point. Tap In or Out first to choose.", tableName: "Snips")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func pointTile(_ point: SpanPoints.Point, label: Text, ms: Int) -> some View {
    let selected = pinned == point
    return Button(action: {
      Haptics.selection()
      pinned = selected ? nil : point
    }) {
      VStack(spacing: 2) {
        label
          .font(.caption)
          .foregroundStyle(selected ? Color.accentColor : .secondary)
        Text(SnipFormatting.clock(ms))
          .font(.headline.monospacedDigit())
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var wordsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if window.fromMs > 0 {
        windowButton(Text("Earlier", tableName: "Snips"), systemImage: "chevron.up") {
          window.fromMs = max(0, window.fromMs - Self.contextMs)
        }
      }

      if loading {
        ProgressView()
          .frame(maxWidth: .infinity)
      } else if words.isEmpty {
        Text("No transcript for this stretch yet. It fills in once the book's text reaches here.", tableName: "Snips")
          .font(.body)
          .italic()
          .foregroundStyle(.secondary)
      } else {
        WordFlowLayout(spacing: 1, lineSpacing: 6) {
          ForEach(words) { word in
            let inside = inSpan(word)
            Text(word.text)
              .font(.body)
              .foregroundStyle(inside ? Color.primary : Color.secondary)
              .padding(.horizontal, 2.5)
              .padding(.vertical, 2)
              .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .fill(inside ? Color.accentColor.opacity(0.28) : .clear)
              )
              .contentShape(Rectangle())
              .onTapGesture { tap(word) }
              .id(word.id)
          }
        }
      }

      if window.toMs < durationMs {
        windowButton(Text("Later", tableName: "Snips"), systemImage: "chevron.down") {
          window.toMs = min(durationMs, window.toMs + Self.contextMs)
        }
      }
    }
  }

  private func windowButton(_ label: Text, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: {
      action()
      Task { await loadWindow() }
    }) {
      Label {
        label
      } icon: {
        Image(systemName: systemImage)
      }
      .font(.subheadline)
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  /// A tapped word moves the pinned point, or whichever end of the span is nearer: In to the word's
  /// start, Out to its end.
  private func tap(_ word: Word) {
    let point: SpanPoints.Point
    if let pinned {
      point = pinned
    } else {
      point = abs(word.startMs - draft.startMs) <= abs(word.endMs - draft.endMs) ? .in : .out
    }
    Haptics.selection()
    let next = SpanPoints.set(point, at: point == .in ? word.startMs : word.endMs, in: span, durationMs: durationMs)
    draft.startMs = next.startMs
    draft.endMs = next.endMs
  }

  private func loadWindow() async {
    loading = segments.isEmpty
    segments = await bridge.segments(itemID: draft.itemID, fromMs: window.fromMs, toMs: window.toMs)
    loading = false
  }

  // MARK: - Note and actions

  private var actions: some View {
    HStack(spacing: 12) {
      Button(action: {
        SnipPlayback.play(draft)
        dismiss()
      }) {
        Label {
          Text("Play from In", tableName: "Snips")
        } icon: {
          Image(systemName: "play.fill")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      Button(
        role: .destructive,
        action: {
          Task {
            await bridge.delete(draft)
            dismiss()
          }
        }
      ) {
        Label {
          Text("Delete", tableName: "Snips")
        } icon: {
          Image(systemName: "trash")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(.red)
    }
    .controlSize(.large)
  }

  private func save() async {
    var record = draft
    record.note = normalizedNote
    if changed {
      // The excerpt is the span's words as they stand now.
      record = await bridge.withFreshExcerpt(record)
      await bridge.save(record)
    }
    dismiss()
  }
}

/// The editor's note, held by reference so typing doesn't invalidate the editor.
final class NoteDraft {
  var text: String
  init(_ text: String) { self.text = text }
}

/// The note bar pinned under the editor's words: its own text state, written through to the draft.
private struct SnipNoteField: View {
  let note: NoteDraft
  let focusOnAppear: Bool
  @State private var text: String
  @FocusState private var focused: Bool

  init(note: NoteDraft, focusOnAppear: Bool) {
    self.note = note
    self.focusOnAppear = focusOnAppear
    _text = State(initialValue: note.text)
  }

  var body: some View {
    TextField("", text: $text, prompt: Text("Add a note", tableName: "Snips"), axis: .vertical)
      .lineLimit(1...6)
      .textFieldStyle(.plain)
      .focused($focused)
      .accessibilityLabel(Text("Note", tableName: "Snips"))
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
      )
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
      .onChange(of: text) { _, new in note.text = new }
      .task {
        // After the sheet's own presentation, or the focus request is dropped.
        guard focusOnAppear else { return }
        try? await Task.sleep(for: .milliseconds(450))
        focused = true
      }
  }
}
