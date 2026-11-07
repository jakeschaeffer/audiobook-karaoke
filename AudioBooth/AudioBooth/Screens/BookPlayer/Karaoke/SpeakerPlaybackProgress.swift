import SwiftUI

// The personal build’s daemon-driven speaker stack; the store build compiles it out
// wholesale (see FORK-NOTES “The two builds”).
#if SPEAKER_STACK

/// The player's progress strip, driven by the speaker session instead of the local `AudioPlayer`.
///
/// During a speaker session the local player is legitimately paused, so the stock scrubber froze at
/// the handoff position — the pill said "Playing on Speaker" while the playhead sat still. This
/// swaps in (via `BookPlayerPlaybackSection`) whenever the manager has a live session for the book:
/// same `PlaybackProgressView`, but its model syncs from the session's interpolated position twice a
/// second, and dragging the scrubber seeks the *speaker*. The moment the session ends, the section
/// swaps back to the local model.
struct SpeakerProgressStrip: View {
  let speaker: SpeakerSessionModel
  @ObservedObject var bookModel: BookPlayer.Model

  @State private var proxy: SpeakerProgressModel?

  var body: some View {
    Group {
      if let proxy {
        PlaybackProgressView(
          model: Binding(get: { proxy }, set: { _ in })
        )
      } else {
        // One frame at most, before .task lands.
        PlaybackProgressView(model: $bookModel.playbackProgress)
      }
    }
    .task(id: speaker.itemID) {
      proxy = SpeakerProgressModel(
        speaker: speaker,
        total: bookModel.playbackProgress.total,
        title: bookModel.playbackProgress.title
      )
    }
    .onDisappear {
      proxy = nil
    }
  }
}

/// Book-absolute times only — the local model's chapter-relative display needs the chapter engine,
/// which isn't worth duplicating for the speaker path.
final class SpeakerProgressModel: PlaybackProgressView.Model {
  private let speaker: SpeakerSessionModel
  private var ticker: Task<Void, Never>?

  @MainActor
  init(speaker: SpeakerSessionModel, total: TimeInterval, title: String) {
    self.speaker = speaker
    super.init(
      progress: 0,
      current: 0,
      remaining: total,
      total: total,
      totalProgress: 0,
      totalTimeRemaining: total,
      title: title
    )
    sync()
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        self?.sync()
      }
    }
  }

  isolated deinit {
    ticker?.cancel()
  }

  @MainActor
  private func sync() {
    guard !isDragging, total > 0 else { return }
    let position = min(max(speaker.currentPosition, 0), total)
    current = position
    remaining = total - position
    progress = position / total
    totalProgress = progress
    totalTimeRemaining = total - position
  }

  override func onProgressChanged(_ progress: Double) {
    let target = progress * total
    Task { @MainActor [speaker] in
      speaker.seek(to: target)
    }
  }
}
#endif
