import Foundation
import Testing

@testable import Transcription

@Suite("Remote playback state decoding")
struct RemotePlaybackStateTests {
  @Test("Active state decodes — fixture verbatim from a live /status probe")
  func activeState() throws {
    let json = """
      {"state": "paused", "title": "Harry Potter And The Goblet Of Fire",
       "item_id": "f4f72906-0548-45b2-b75a-44d08826e458",
       "session_id": "2cb823a2-154b-4fb3-b38e-eac20320165b",
       "position": 22756.3, "duration": 72830.2, "remaining": 50073.9,
       "percent": 31.25, "track": "16/39", "volume": null,
       "wiim_host": "192.0.2.20"}
      """
    let state = try JSONDecoder().decode(RemotePlaybackState.self, from: Data(json.utf8))
    #expect(state.isPaused)
    #expect(state.hasSession)
    #expect(state.itemID == "f4f72906-0548-45b2-b75a-44d08826e458")
    #expect(state.position == 22756.3)
    #expect(state.track == "16/39")
    #expect(state.volume == nil)  // only present when the daemon polled the device
  }

  @Test("Idle state decodes — nulls everywhere and no item_id key at all")
  func idleState() throws {
    // public_state() omits item_id entirely when idle rather than sending null.
    let json = """
      {"state": "idle", "title": null, "position": null, "duration": null,
       "percent": null, "track": null, "wiim_host": "192.0.2.20"}
      """
    let state = try JSONDecoder().decode(RemotePlaybackState.self, from: Data(json.utf8))
    #expect(state.isIdle)
    #expect(!state.hasSession)
    #expect(state.itemID == nil)
  }

  @Test("WS frames carry an extra type key and still decode as the same shape")
  func wsFrame() throws {
    let json = """
      {"type": "state", "state": "playing", "title": "Goblet",
       "item_id": "f4f72906", "session_id": "s", "position": 22757.3,
       "duration": 72830.2, "remaining": 50072.9, "percent": 31.25,
       "track": "16/39", "volume": 20, "wiim_host": "192.0.2.20"}
      """
    let state = try JSONDecoder().decode(RemotePlaybackState.self, from: Data(json.utf8))
    #expect(state.isPlaying)
    #expect(state.volume == 20)
  }

  @Test("An unknown phase degrades to not-playing instead of failing to decode")
  func unknownPhase() throws {
    let json = #"{"state": "stalled", "wiim_host": "x"}"#
    let state = try JSONDecoder().decode(RemotePlaybackState.self, from: Data(json.utf8))
    #expect(!state.isPlaying)
    #expect(!state.isIdle)
    #expect(!state.hasSession)
  }
}

@Suite("Events socket URL")
struct SocketURLTests {
  @Test("http daemon maps to ws, https to wss")
  func schemeMapping() {
    #expect(
      DaemonEventsSocket.socketURL(for: URL(string: "http://192.0.2.10:8788")!)?.absoluteString
        == "ws://192.0.2.10:8788/events"
    )
    #expect(
      DaemonEventsSocket.socketURL(for: URL(string: "https://captions.example.com")!)?.absoluteString
        == "wss://captions.example.com/events"
    )
  }
}

/// Read-only checks against the live daemon — no transport commands are ever sent from tests; the
/// speaker is a real device in a real bedroom.
@Suite(
  "LiveTransport",
  .enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTION_LIVE"] == "1")
)
struct LiveTransportTests {
  @Test("GET /status decodes against the running daemon")
  func liveStatus() async throws {
    let state = try await DaemonTransportClient(endpoint: .live).status()
    #expect(!state.state.isEmpty)
    // Whatever the speaker is doing right now, the shape must hold.
    if state.hasSession {
      #expect(state.itemID != nil)
      #expect((state.duration ?? 0) > 0)
    }
  }

  @Test("WS /events delivers the initial state frame")
  func liveEventsFirstFrame() async throws {
    let socket = DaemonEventsSocket(endpoint: .live)
    var first: RemotePlaybackState?
    for await state in socket.states() {
      first = state
      break
    }
    let state = try #require(first)
    #expect(!state.state.isEmpty)
  }
}
