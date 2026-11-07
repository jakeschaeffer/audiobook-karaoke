import Models
import SwiftUI
import Transcription

/// Listening sessions reconstructed from the playback-history event log — "where was I on Tuesday
/// night," answered as tappable position ranges. Chunking lives in `ListeningSessionChunker`
/// (Transcription package), where it's unit-tested; this view only maps and renders.
struct SessionHistoryList: View {
  /// Flattened event rows from the sheet's already-loaded sections (any order).
  let events: [PlaybackHistoryRow.Model]
  let onTap: (TimeInterval) -> Void

  var body: some View {
    let daySections = Self.daySections(from: Self.sessions(from: events))
    if daySections.isEmpty {
      ContentUnavailableView(
        "No Sessions",
        systemImage: "clock.arrow.circlepath",
        description: Text("Listening sessions will appear here after you play this book.")
      )
    } else {
      List {
        ForEach(daySections) { section in
          Section(header: Text(section.title)) {
            ForEach(section.sessions) { identified in
              let session = identified.session
              Button(action: { onTap(session.endPosition) }) {
                row(session)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
    }
  }

  private func row(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(timeRange(session))
          .font(.subheadline.weight(.medium))
        Spacer()
        if session.listenedSeconds >= 60 {
          Text("≈\(Int(session.listenedSeconds / 60)) min")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 6) {
        Text(position(session.startPosition))
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(position(session.endPosition))
          .fontWeight(.semibold)
      }
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  private func timeRange(_ session: Session) -> String {
    let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
    let start = session.startedAt.formatted(time)
    let end = session.endedAt.formatted(time)
    return start == end ? start : "\(start) – \(end)"
  }

  private func position(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2)))
  }

  // MARK: - Mapping

  typealias Session = ListeningSession

  struct IdentifiedSession: Identifiable {
    let id: String
    let session: Session
  }

  struct DaySection: Identifiable {
    let id = UUID()
    let title: String
    let sessions: [IdentifiedSession]
  }

  static func sessions(from events: [PlaybackHistoryRow.Model]) -> [Session] {
    ListeningSessionChunker.sessions(
      from: events.map { ListeningEvent(position: $0.position, timestamp: $0.timestamp) }
    )
  }

  static func daySections(from sessions: [Session]) -> [DaySection] {
    let calendar = Calendar.current
    var order: [String] = []
    var grouped: [String: [IdentifiedSession]] = [:]
    for session in sessions {
      let title: String =
        if calendar.isDateInToday(session.startedAt) {
          String(localized: "Today")
        } else if calendar.isDateInYesterday(session.startedAt) {
          String(localized: "Yesterday")
        } else {
          session.startedAt.formatted(date: .abbreviated, time: .omitted)
        }
      if grouped[title] == nil {
        grouped[title] = []
        order.append(title)
      }
      grouped[title]?.append(
        IdentifiedSession(
          id: "\(session.startedAt.timeIntervalSince1970)-\(session.startPosition)",
          session: session
        )
      )
    }
    return order.map { DaySection(title: $0, sessions: grouped[$0] ?? []) }
  }
}
