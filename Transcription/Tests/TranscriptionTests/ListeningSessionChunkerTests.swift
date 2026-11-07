import Foundation
import Testing

@testable import Transcription

@Suite("Listening session chunking")
struct ListeningSessionChunkerTests {
  private let epoch = Date(timeIntervalSince1970: 1_784_000_000)

  private func event(t: TimeInterval, pos: TimeInterval) -> ListeningEvent {
    ListeningEvent(position: pos, timestamp: epoch.addingTimeInterval(t))
  }

  @Test("A continuous listen is one session despite the long gap between its boundary events")
  func continuousListenSurvivesGap() {
    // play at pos 1000, pause 40 minutes later at pos 3400: the only two events. A wall-gap rule
    // alone would split them into two one-event sessions.
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 1000),
      event(t: 2400, pos: 3400),
    ])
    #expect(sessions.count == 1)
    #expect(sessions[0].startPosition == 1000)
    #expect(sessions[0].endPosition == 3400)
    #expect(abs(sessions[0].listenedSeconds - 2400) < 1)
  }

  @Test("An overnight break splits into two sessions")
  func overnightBreakSplits() {
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 1000),
      event(t: 1800, pos: 2800),  // pause after 30 min
      event(t: 30000, pos: 2800),  // resume ~8h later at the same position
      event(t: 31800, pos: 4600),  // pause after another 30 min
    ])
    #expect(sessions.count == 2)
    // reversed(): newest first
    #expect(sessions[0].startPosition == 2800)
    #expect(sessions[1].endPosition == 2800)
  }

  @Test("App killed mid-listen splits despite the missing pause event")
  func appKilledSplits() {
    // play, then nothing (killed — no pause event) — the next events are tomorrow's listen starting
    // near the same position: the wall clock jumped but the playhead didn't, so the gap was idle.
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 1000),
      event(t: 600, pos: 1600),  // a seek event mid-listen, then the app dies
      event(t: 90000, pos: 1650),  // next day: resume ~where it died
      event(t: 90600, pos: 2250),  // and listen for ten minutes
    ])
    #expect(sessions.count == 2)
    #expect(sessions[0].startPosition == 1650)
    #expect(sessions[1].endPosition == 1600)
  }

  @Test("Reduced playback speed still counts as listening through a gap")
  func slowSpeedSurvives() {
    // 40-minute wall gap, position advanced 24 min (0.6x speed): listened, one session.
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 0),
      event(t: 2400, pos: 1440),
    ])
    #expect(sessions.count == 1)
  }

  @Test("A forward seek doesn't inflate listened time")
  func seekDoesNotInflateListened() {
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 1000),
      event(t: 10, pos: 4000),  // +50 min position in 10s wall: a seek
      event(t: 610, pos: 4600),  // then 10 min of real listening
    ])
    #expect(sessions.count == 1)
    #expect(sessions[0].listenedSeconds < 700)
    #expect(sessions[0].startPosition == 1000)
    #expect(sessions[0].endPosition == 4600)
  }

  @Test("Opened-and-closed noise is filtered out")
  func noiseFiltered() {
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 1000),
      event(t: 3, pos: 1001),  // opened the player, closed it 3s later
    ])
    #expect(sessions.isEmpty)
  }

  @Test("Sessions come back newest first")
  func newestFirst() {
    let sessions = ListeningSessionChunker.sessions(from: [
      event(t: 0, pos: 0),
      event(t: 300, pos: 300),
      event(t: 100_000, pos: 300),
      event(t: 100_300, pos: 600),
    ])
    #expect(sessions.count == 2)
    #expect(sessions[0].startedAt > sessions[1].startedAt)
  }
}
