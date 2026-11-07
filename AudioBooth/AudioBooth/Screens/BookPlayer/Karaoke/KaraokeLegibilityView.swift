import SwiftUI
import Transcription

/// Landscape reading mode: no chrome, just text as big as it can be.
///
/// Two fixed slots split the screen, and they never move. One holds the piece being spoken, the
/// other what's next; the moment speech crosses into the next piece — which is already on screen
/// in its slot — the slot just vacated dissolves (500 ms crossfade, in place) to the piece after
/// that. The highlight ping-pongs top → bottom → top while each idle slot quietly becomes the
/// future, so the only motions on screen are opacity: word-glow ticks and one dissolve per
/// piece. No scrolling, no pushes, no layout changes — slot heights are fixed halves, and every
/// piece renders from one canonical glyph stream (`TranscriptText.styled`), so highlight state
/// can never rewrap a line.
///
/// Slots hold *pieces*, not segments: a run-on segment is cut at clause boundaries into pieces of
/// at most `pieceLimit` characters (`TranscriptSegment.displayPieces`), because the size (64pt)
/// is a ceiling a whole paragraph would shrink far below. A piece that still doesn't fit shrinks
/// alone; short ones render at full size.
struct KaraokeLegibilityView: View {
  let model: KaraokeSheet.Model
  @ObservedObject private var playerManager = PlayerManager.shared

  /// The size ceiling. Deliberately large: long segments shrink per-slot anyway, so the cost
  /// of a big value is zero and the benefit is legibility.
  private let fontSize: Double = 64

  /// About three lines of a slot at the full size — the budget that keeps text near the ceiling.
  private static let pieceLimit = 60

  /// The slots' occupants. State rather than derived: a piece stays in the slot it was first
  /// shown in when it becomes the active one, which is what makes activation a pure highlight.
  @State private var top: Piece?
  @State private var bottom: Piece?

  @State private var controlsVisible = false
  @State private var hideControls: Task<Void, Never>?

  var body: some View {
    ZStack {
      // Full-bleed black regardless of theme: contrast is the whole point of this mode.
      Color.black.ignoresSafeArea()

      if live != nil {
        VStack(alignment: .leading, spacing: 14) {
          slot(top)
          slot(bottom)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
      } else {
        // The playhead is outside the loaded text; the follow recentre lands within a beat.
        ProgressView()
          .tint(.white)
      }
    }
    .contentShape(Rectangle())
    // The classic video-player idiom: tap to summon the transport, tap or a few idle seconds
    // to dismiss it. The mode stays all-text the rest of the time.
    .onTapGesture { toggleControls() }
    .overlay {
      if controlsVisible {
        transportOverlay
      }
    }
    .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    .persistentSystemOverlays(.hidden)
    .onChange(of: PlacementKey(active: live?.active.key, next: live?.next?.key), initial: true) {
      place(live)
    }
    .onAppear {
      // Entering the reading display means "track playback" — resume following even if the
      // portrait view had been browsed away — and hold the screen awake: this surface exists
      // to be stared at for an hour.
      model.returnToPlayhead()
      ScreenWakeCoordinator.shared.acquire(Self.wakeToken)
    }
    .onDisappear {
      ScreenWakeCoordinator.shared.release(Self.wakeToken)
    }
  }

  private static let wakeToken = "karaoke-legibility"

  // MARK: - Slots

  /// The piece under the playhead and the one after it — within the active segment, or the first
  /// piece of the next segment when it directly follows. Only these one or two segments are cut,
  /// so recomputing per tick stays cheap.
  private var live: (active: Piece, next: Piece?)? {
    let segments = model.segments
    let index = model.activeIndex
    guard index >= 0, index < segments.count else { return nil }
    let segment = segments[index]
    let pieces = segment.displayPieces(maxCharacters: Self.pieceLimit)
    let current = pieces.lastIndex { $0.start <= model.position } ?? 0
    let active = Piece(key: PieceKey(seg: segment.seg, index: current), segment: pieces[current])
    if current + 1 < pieces.count {
      let next = PieceKey(seg: segment.seg, index: current + 1)
      return (active, Piece(key: next, segment: pieces[current + 1]))
    }
    guard index + 1 < segments.count, segments[index + 1].seg == segment.seg + 1,
      let first = segments[index + 1].displayPieces(maxCharacters: Self.pieceLimit).first
    else { return (active, nil) }
    return (active, Piece(key: PieceKey(seg: segments[index + 1].seg, index: 0), segment: first))
  }

  /// Keep the active piece where it already is and put what's next in the other slot. A piece
  /// that isn't on screen (open, seek) starts at the top.
  private func place(_ live: (active: Piece, next: Piece?)?) {
    guard let live else {
      top = nil
      bottom = nil
      return
    }
    if top?.key == live.active.key {
      bottom = live.next
    } else if bottom?.key == live.active.key {
      top = live.next
    } else {
      top = live.active
      bottom = live.next
    }
  }

  @ViewBuilder
  private func slot(_ piece: Piece?) -> some View {
    ZStack {
      if let piece {
        let live = live
        let isActive = piece.key == live?.active.key
        // Render the live cut when it's one of the two current pieces: slots remember *which*
        // piece they hold, but a cleaner transcript tier landing mid-read should show at once.
        let fresh = isActive ? live?.active : (piece.key == live?.next?.key ? live?.next : nil)
        Text(
          TranscriptText.styled(
            (fresh ?? piece).segment,
            position: model.position,
            isActive: isActive,
            active: .white,
            pending: .white.opacity(0.45),
            rest: isActive ? .white : .white.opacity(0.35)
          )
        )
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .minimumScaleFactor(0.3)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Identity is the piece: when this slot's occupant changes, the old text fades out as
        // the new fades in — the dissolve — while the frame holds perfectly still.
        .id(piece.key)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Keyed to the occupant — `nil` while empty, so an empty→filled edge also fades.
    .animation(.easeInOut(duration: 0.5), value: piece?.key)
  }

  // MARK: - Transport overlay

  private var transportOverlay: some View {
    HStack(spacing: 56) {
      transportButton("gobackward.15", size: 34, label: "Skip back 15 seconds") {
        skip(-15)
      }
      transportButton(
        isPlaying ? "pause.fill" : "play.fill",
        size: 50,
        label: isPlaying ? "Pause" : "Play"
      ) {
        togglePlayback()
      }
      transportButton("goforward.15", size: 34, label: "Skip forward 15 seconds") {
        skip(15)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // A light wash so the controls read over bright text without hiding the page.
    .background(Color.black.opacity(0.35))
    .transition(.opacity)
  }

  private func transportButton(
    _ systemImage: String,
    size: CGFloat,
    label: LocalizedStringKey,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      scheduleControlsHide()
    } label: {
      Image(systemName: systemImage)
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: size + 38, height: size + 38)
        .background(.white.opacity(0.14), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func toggleControls() {
    if controlsVisible {
      hideControls?.cancel()
      controlsVisible = false
    } else {
      controlsVisible = true
      scheduleControlsHide()
    }
  }

  private func scheduleControlsHide() {
    hideControls?.cancel()
    hideControls = Task { @MainActor in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      controlsVisible = false
    }
  }

  // MARK: - Output routing

  /// The same rule as every other transport (see SPEAKER.md): the speaker drives while it's the
  /// active output, the phone otherwise — this surface adds no routing opinions of its own.
  #if SPEAKER_STACK
  private var speaker: SpeakerSessionModel? {
    SpeakerSessionManager.shared.activeSession(for: model.itemID)
  }
  #endif

  private var isPlaying: Bool {
    #if SPEAKER_STACK
    if let speaker { return speaker.isPlaying }
    #endif
    guard let current = playerManager.current, current.id == model.itemID else { return false }
    return current.isPlaying
  }

  private func togglePlayback() {
    #if SPEAKER_STACK
    if let speaker {
      speaker.togglePlayback()
      return
    }
    #endif
    if let current = playerManager.current, current.id == model.itemID {
      current.isPlaying ? playerManager.pause() : playerManager.play()
    } else {
      // Reading a book that isn't loaded: play means "start it here", same as the output bar.
      Task { await playerManager.play(model.itemID) }
    }
  }

  private func skip(_ seconds: TimeInterval) {
    #if SPEAKER_STACK
    if let speaker {
      speaker.skip(seconds)
      return
    }
    #endif
    guard let current = playerManager.current, current.id == model.itemID else { return }
    if seconds < 0 {
      current.onSkipBackwardTapped(seconds: -seconds)
    } else {
      current.onSkipForwardTapped(seconds: seconds)
    }
  }
}

/// A displayed piece: which segment, which cut of it, and the piece itself to render.
private struct Piece: Equatable {
  let key: PieceKey
  let segment: TranscriptSegment
}

private struct PieceKey: Hashable {
  let seg: Int
  let index: Int
}

/// What placement reacts to — the pieces' identities, not the per-tick word glow.
private struct PlacementKey: Equatable {
  let active: PieceKey?
  let next: PieceKey?
}
