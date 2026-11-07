import AppIntents
import Models
import PlayerIntents
import SwiftUI
import WidgetKit

struct CircularBookWidgetView: View {
  let entry: AudioBoothWidgetEntry

  var body: some View {
    if let playbackState = entry.playbackState {
      bookView(playbackState: playbackState)
    } else {
      emptyStateView
    }
  }

  private func bookView(playbackState: PlaybackState) -> some View {
    ZStack {
      AccessoryWidgetBackground()

      Button(intent: OpenBookIntent(bookID: playbackState.bookID)) {
        Gauge(value: playbackState.progress, in: 0...1) {
          EmptyView()
        } currentValueLabel: {
          icon
        }
        .gaugeStyle(.accessoryCircular)
      }
      .buttonStyle(.plain)
    }
  }

  private var emptyStateView: some View {
    ZStack {
      AccessoryWidgetBackground()

      Button(intent: OpenBookIntent()) {
        Gauge(value: 0) {
          EmptyView()
        } currentValueLabel: {
          icon
        }
        .gaugeStyle(.accessoryCircular)
      }
      .buttonStyle(.plain)
    }
  }

  private var icon: some View {
    Label(String("AudioBook Karaoke"), image: "audiobooth.fill")
      .labelStyle(.iconOnly)
  }
}
