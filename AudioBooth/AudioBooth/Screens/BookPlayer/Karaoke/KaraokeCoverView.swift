import Models
import SwiftUI
import Transcription

/// Karaoke mode for the full player: the streaming transcript rendered inside the album cover's
/// square, entered from the cover's long-press menu.
///
/// This is a *renderer*, not a second engine — it drives the same `KaraokeSheet.Model` the
/// transcript sheet uses (ticker, windowing, active-line pick, JIT chunk fetch all included), so
/// there is exactly one transcript pipeline in the app. What differs is the surface: no paging, no
/// user scrolling, no controls — an ambient, always-following view sized and styled like the cover
/// it replaces. Line-level emphasis rather than word karaoke on purpose: cleaned and ebook-aligned
/// tiers drop word timings, so lines are the one grain every provenance tier can honor.
struct KaraokeCoverView: View {
  @ObservedObject var model: BookPlayer.Model
  @ObservedObject private var preferences = UserPreferences.shared

  @State private var karaoke: KaraokeSheet.Model?
  /// Whether the square has been centred on the playhead yet: the first placement jumps, only
  /// line changes after it glide (animating the first one scrolled through the whole window).
  @State private var positioned = false

  /// Characters per displayed piece: about four lines of the square's text, so the active piece
  /// always fits the unmasked band — run-on sentences used to overflow above and below it.
  private static let pieceLimit = 120

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: preferences.cardCoverCornerRadius.value)
        .fill(.black.opacity(0.35))
        .background(
          .ultraThinMaterial,
          in: RoundedRectangle(cornerRadius: preferences.cardCoverCornerRadius.value)
        )
      content
        .clipShape(RoundedRectangle(cornerRadius: preferences.cardCoverCornerRadius.value))
    }
    .frame(minWidth: 200, maxWidth: 400, minHeight: 200, maxHeight: 400)
    .aspectRatio(1, contentMode: .fit)
    .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    .contextMenu {
      Button {
        withAnimation { preferences.playerKaraokeCover = false }
      } label: {
        Label("Show Cover", systemImage: "photo")
      }
      Button {
        model.isKaraokePresented = true
      } label: {
        Label("Open Full Transcript", systemImage: "text.bubble")
      }
    }
    .accessibilityLabel("Karaoke view. Long press for options.")
    // Keyed to the book: when the queue advances, tear down and rebuild for the new item.
    .task(id: model.id) {
      karaoke?.stop()
      let progress = try? MediaProgress.getOrCreate(
        for: model.id,
        duration: model.playbackProgress.total
      )
      let sheetModel = KaraokeSheet.Model(
        itemID: model.id,
        duration: model.playbackProgress.total,
        chapters: (model.chapters?.chapters ?? []).map {
          KaraokeSheet.Model.ChapterMarker(id: $0.id, title: $0.title, start: $0.start, end: $0.end)
        },
        bookContext: model.author.map { "\(model.title) by \($0)" } ?? model.title,
        displayPieceLimit: Self.pieceLimit,
        // Consulted per tick: while the speaker plays this book the cover streams the speaker's
        // playhead (this is what kept the cover from looking paused after the speaker sheet
        // closed); the moment the session ends it falls back to local progress.
        positionProvider: { [id = model.id] in
          {
            #if SPEAKER_STACK
            if let live = SpeakerSessionManager.shared.livePosition(for: id) { return live }
            #endif
            return PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
          }()
        },
        onSeek: { [id = model.id] time in
          #if SPEAKER_STACK
          if let speaker = SpeakerSessionManager.shared.activeSession(for: id) {
            speaker.seek(to: time)
            return
          }
          #endif
          _ = id
          model.onSeekToTime(time)
        }
      )
      positioned = false
      karaoke = sheetModel
      await sheetModel.start()
    }
    .onDisappear {
      karaoke?.stop()
      karaoke = nil
    }
  }

  @ViewBuilder
  private var content: some View {
    if let karaoke {
      switch karaoke.state {
      case .loading:
        ProgressView()
      case .ready:
        lines(karaoke)
      case .missingTranscript:
        placeholder(
          "No transcript yet",
          detail: "Open the transcript from the player menu to create one."
        )
      case .noAudio:
        placeholder("This item has no audio", detail: nil)
      case .storeUnavailable:
        placeholder("Transcript storage unavailable", detail: nil)
      }
    } else {
      ProgressView()
    }
  }

  private func lines(_ karaoke: KaraokeSheet.Model) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        // A plain VStack, deliberately: LazyVStack estimates offscreen row heights, so every
        // scrollTo lands slightly off and later corrects — the "text jumps around" feel. The
        // window holds a few dozen rows; laying them all out is cheap and makes anchors exact.
        VStack(alignment: .leading, spacing: 14) {
          ForEach(karaoke.rows) { row in
            switch row {
            case .chapter(let marker):
              Text(marker.title)
                .font(.footnote.smallCaps().weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
            case .line(let index, let segment):
              line(
                segment,
                isActive: index == karaoke.activeIndex,
                isPast: index < karaoke.activeIndex
              )
            }
          }
        }
        // Half-square top/bottom padding lets the first and last lines still center.
        .padding(.vertical, 170)
        .padding(.horizontal, 22)
      }
      // Ambient surface: the transcript follows playback, always. Reading around freely is the
      // sheet's job — this square has no room for paging affordances.
      .scrollDisabled(true)
      .onChange(of: karaoke.activeRowID, initial: true) { _, id in
        guard let id else { return }
        guard positioned else {
          proxy.scrollTo(id, anchor: .center)
          positioned = true
          return
        }
        withAnimation(.easeInOut(duration: 0.4)) {
          proxy.scrollTo(id, anchor: .center)
        }
      }
      // The maintenance loop slides the loaded window as the playhead advances, rebuilding
      // `rows` — which silently shifts everything under a scroll position anchored to nothing.
      // Re-center instantly (no animation) so the rebuild is invisible, instead of drifting
      // until the next active-line change happens to re-center it.
      .onChange(of: karaoke.rows) { _, _ in
        guard let id = karaoke.activeRowID else { return }
        proxy.scrollTo(id, anchor: .center)
      }
      .onAppear { karaoke.follow = true }
      .onDisappear { positioned = false }
    }
    .mask(
      // Fade the edges so lines stream in and out instead of popping at the clip boundary.
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black, location: 0.18),
          .init(color: .black, location: 0.82),
          .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func line(_ segment: TranscriptSegment, isActive: Bool, isPast: Bool) -> some View {
    // One fixed weight for every state. A weight change on focus re-measures the glyphs and
    // re-wraps the paragraph — words visibly hopped between rows the moment a line came into
    // focus. Emphasis is carried entirely by brightness and a scale transform, neither of which
    // participates in layout, so the wrap is stable by construction.
    Text(segment.text)
      .font(.title3.weight(.semibold))
      .foregroundStyle(
        isActive ? .white : isPast ? .white.opacity(0.30) : .white.opacity(0.50)
      )
      .scaleEffect(isActive ? 1.0 : 0.97, anchor: .leading)
      .animation(.easeInOut(duration: 0.3), value: isActive)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func placeholder(_ title: String, detail: String?) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "text.bubble")
        .font(.title2)
        .foregroundStyle(.white.opacity(0.4))
      Text(title)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white.opacity(0.7))
      if let detail {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.45))
          .multilineTextAlignment(.center)
      }
    }
    .padding(24)
  }
}
