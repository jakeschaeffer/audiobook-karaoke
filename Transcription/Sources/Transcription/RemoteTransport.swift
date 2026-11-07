import Foundation

/// The daemon's `public_state` — one shape for `GET /status`, every transport POST's response, and
/// the WS `/events` payloads.
///
/// When idle most fields are null and `item_id` is absent entirely, so everything but `state` is
/// optional. `state` stays a raw string with predicate helpers rather than an enum: the daemon's
/// vocabulary ("playing", "paused", "idle") can grow, and an unknown phase must degrade to "not
/// playing", not to a decode failure that kills the whole event stream.
public struct RemotePlaybackState: Decodable, Equatable, Sendable {
  public let state: String
  public let title: String?
  public let itemID: String?
  public let sessionID: String?
  /// Book-absolute seconds.
  public let position: TimeInterval?
  public let duration: TimeInterval?
  public let percent: Double?
  /// e.g. `"16/39"`.
  public let track: String?
  /// 0–100. Only present when the daemon polled the device for this update.
  public let volume: Int?

  public var isPlaying: Bool { state == "playing" }
  public var isPaused: Bool { state == "paused" }
  public var isIdle: Bool { state == "idle" }
  /// A session exists (playing or paused) — seeks are valid; when false, a seek must become a play.
  public var hasSession: Bool { itemID != nil && !isIdle }

  private enum CodingKeys: String, CodingKey {
    case state, title, position, duration, percent, track, volume
    case itemID = "item_id"
    case sessionID = "session_id"
  }

  public init(
    state: String,
    title: String? = nil,
    itemID: String? = nil,
    sessionID: String? = nil,
    position: TimeInterval? = nil,
    duration: TimeInterval? = nil,
    percent: Double? = nil,
    track: String? = nil,
    volume: Int? = nil
  ) {
    self.state = state
    self.title = title
    self.itemID = itemID
    self.sessionID = sessionID
    self.position = position
    self.duration = duration
    self.percent = percent
    self.track = track
    self.volume = volume
  }
}

/// Drives WiiM playback through the abs-session daemon's transport endpoints.
///
/// Always through the daemon, never the speaker directly: the daemon owns the ABS session, syncs
/// progress upstream, and publishes every state change to Home Assistant over MQTT (retained
/// `abs_session/*` topics with HA discovery) and to WS listeners. Commanding the daemon is what
/// keeps the phone, HA dashboards, and the speaker telling one story — a direct UPnP path would
/// fork the state three ways.
public struct DaemonTransportClient: Sendable {
  private let endpoint: DaemonEndpoint
  private let session: URLSession
  private let authorization: AuthorizationProvider?

  public init(
    endpoint: DaemonEndpoint = .current,
    session: URLSession = .shared,
    authorization: AuthorizationProvider? = nil
  ) {
    self.endpoint = endpoint
    self.session = session
    self.authorization = authorization
  }

  /// `POST /play` — start (or restart) an item on the speaker. `position` is book-absolute; omitting
  /// it resumes from the daemon's stored position with its configured rewind.
  @discardableResult
  public func play(
    itemID: String,
    position: TimeInterval? = nil
  ) async throws
    -> RemotePlaybackState
  {
    var body: [String: Any] = ["item_id": itemID]
    if let position { body["position"] = position }
    return try await post("play", body: body)
  }

  @discardableResult
  public func toggle() async throws -> RemotePlaybackState { try await post("toggle") }

  @discardableResult
  public func pause() async throws -> RemotePlaybackState { try await post("pause") }

  @discardableResult
  public func resume() async throws -> RemotePlaybackState { try await post("resume") }

  /// Ends the session with a final progress sync. The speaker stops; the book's position is safe.
  @discardableResult
  public func stop() async throws -> RemotePlaybackState { try await post("stop") }

  /// `POST /seek {position}` — 409 (`.http(409)`) when no session exists; callers turn that into a
  /// `play(itemID:position:)`, mirroring the reference player's "a seek while idle IS starting
  /// playback there".
  @discardableResult
  public func seek(position: TimeInterval) async throws -> RemotePlaybackState {
    try await post("seek", body: ["position": position])
  }

  @discardableResult
  public func seek(delta: TimeInterval) async throws -> RemotePlaybackState {
    try await post("seek", body: ["delta": delta])
  }

  @discardableResult
  public func setVolume(_ level: Int) async throws -> RemotePlaybackState {
    try await post("volume", body: ["level": max(0, min(100, level))])
  }

  public func status() async throws -> RemotePlaybackState {
    var request = URLRequest(url: endpoint.daemon.appending(path: "status"))
    if let bearer = await authorization?() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard http.statusCode == 200 else { throw TranscriptionError.http(status: http.statusCode) }
    return try JSONDecoder().decode(RemotePlaybackState.self, from: data)
  }

  private func post(
    _ path: String,
    body: [String: Any]? = nil
  ) async throws
    -> RemotePlaybackState
  {
    var request = URLRequest(url: endpoint.daemon.appending(path: path))
    request.httpMethod = "POST"
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    if let bearer = await authorization?() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard http.statusCode == 200 else { throw TranscriptionError.http(status: http.statusCode) }
    return try JSONDecoder().decode(RemotePlaybackState.self, from: data)
  }
}
