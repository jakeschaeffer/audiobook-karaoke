import Foundation

/// A playback-history event reduced to what session reconstruction needs.
public struct ListeningEvent: Equatable, Sendable {
  public let position: TimeInterval
  public let timestamp: Date

  public init(position: TimeInterval, timestamp: Date) {
    self.position = position
    self.timestamp = timestamp
  }
}

/// One listening session: a wall-clock span and the book-position range it covered.
public struct ListeningSession: Equatable, Sendable {
  public var startedAt: Date
  public var endedAt: Date
  public var startPosition: TimeInterval
  public var endPosition: TimeInterval
  /// Estimated seconds actually listened, from position advances that look like playback.
  public var listenedSeconds: TimeInterval

  public init(
    startedAt: Date,
    endedAt: Date,
    startPosition: TimeInterval,
    endPosition: TimeInterval,
    listenedSeconds: TimeInterval
  ) {
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.startPosition = startPosition
    self.endPosition = endPosition
    self.listenedSeconds = listenedSeconds
  }
}

/// Reconstructs listening sessions from boundary events (play/pause/seek/…).
///
/// Events only exist at boundaries, so sessions can't be chunked on wall-clock gaps alone: a
/// continuous 40-minute listen is a single play→pause pair with a 40-minute gap between its events.
/// The rule is position-aware — a gap longer than `sessionGap` still belongs to one session when the
/// playhead advanced by at least roughly half the gap (listening, possibly at reduced speed);
/// otherwise the gap was idle time and a new session starts. An app killed mid-listen never writes
/// its pause event, and still splits correctly: the next event's position sits near where the last
/// one left off while the wall clock jumped.
public enum ListeningSessionChunker {
  public static let sessionGap: TimeInterval = 20 * 60

  public static func sessions(
    from events: [ListeningEvent],
    gap sessionGap: TimeInterval = sessionGap
  ) -> [ListeningSession] {
    let ordered = events.sorted { $0.timestamp < $1.timestamp }
    var sessions: [ListeningSession] = []
    var current: ListeningSession?
    var previous: ListeningEvent?

    for event in ordered {
      if var session = current, let last = previous {
        let gap = event.timestamp.timeIntervalSince(last.timestamp)
        let advance = event.position - last.position
        let listenedThroughGap = advance > 0 && advance >= max(gap * 0.5 - 60, 0)
        if gap > sessionGap && !listenedThroughGap {
          sessions.append(session)
          current = ListeningSession(
            startedAt: event.timestamp,
            endedAt: event.timestamp,
            startPosition: event.position,
            endPosition: event.position,
            listenedSeconds: 0
          )
        } else {
          session.endedAt = event.timestamp
          session.endPosition = event.position
          // Count position advances that look like playback (any speed up to ~2.5x, small slack
          // for stamp jitter); a forward seek advances further than the wall clock allows and is
          // excluded, so it doesn't masquerade as listened time.
          if advance > 0 && advance <= gap * 2.5 + 60 {
            session.listenedSeconds += min(advance, max(gap, 1))
          }
          current = session
        }
      } else {
        current = ListeningSession(
          startedAt: event.timestamp,
          endedAt: event.timestamp,
          startPosition: event.position,
          endPosition: event.position,
          listenedSeconds: 0
        )
      }
      previous = event
    }
    if let current { sessions.append(current) }

    // Opened-and-closed noise: a session that neither lasted a minute nor moved the playhead says
    // nothing about "where was I."
    return
      sessions
      .filter {
        $0.endedAt.timeIntervalSince($0.startedAt) >= 60
          || abs($0.endPosition - $0.startPosition) >= 5
      }
      .reversed()
  }
}
