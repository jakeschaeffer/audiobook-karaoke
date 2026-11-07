import Foundation

/// What a companion server says it can do, from `GET /capabilities` on the daemon. The contract is
/// docs/COMPANION-API.md; this app needs nothing about the server beyond the one address the user
/// types and this answer.
public struct CompanionCapabilities: Codable, Sendable, Equatable {
  public enum Feature: String, Codable, Sendable, CaseIterable {
    /// `GET /captions`, `/tracks`: transcripts to follow along with.
    case captions
    /// `GET /audio`: book audio for transcribing a book that isn't downloaded.
    case audio
    /// `/status`, `/events` and the transport POSTs: a speaker the app can hand playback to.
    case speaker
    /// The caption worker: `POST /jobs`, `GET /status`, `PUT /transcripts`.
    case jobs
  }

  /// The highest contract version this build understands.
  public static let supportedAPI = 1

  public var service: String?
  public var api: Int
  public var features: Set<Feature>
  public var workerURL: URL?
  public var speakerName: String?

  public init(
    service: String? = nil,
    api: Int = CompanionCapabilities.supportedAPI,
    features: Set<Feature>,
    workerURL: URL? = nil,
    speakerName: String? = nil
  ) {
    self.service = service
    self.api = api
    self.features = features
    self.workerURL = workerURL
    self.speakerName = speakerName
  }

  private enum CodingKeys: String, CodingKey {
    case service, api, features
    case workerURL = "worker_url"
    case speaker
  }

  private struct Speaker: Codable {
    let name: String?
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    service = try container.decodeIfPresent(String.self, forKey: .service)
    api = try container.decode(Int.self, forKey: .api)
    // A newer server may offer features this build has never heard of; they are not an error.
    features = Set(try container.decode([String].self, forKey: .features).compactMap(Feature.init(rawValue:)))
    workerURL = try? container.decodeIfPresent(URL.self, forKey: .workerURL)
    speakerName = (try? container.decodeIfPresent(Speaker.self, forKey: .speaker))?.name
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(service, forKey: .service)
    try container.encode(api, forKey: .api)
    try container.encode(features.map(\.rawValue).sorted(), forKey: .features)
    try container.encodeIfPresent(workerURL, forKey: .workerURL)
    try container.encodeIfPresent(speakerName.map { Speaker(name: $0) }, forKey: .speaker)
  }
}

public enum CompanionError: Error, Equatable {
  case invalidAddress
  case unreachable
  /// The daemon wants a login this phone doesn't have: sign in to Audiobookshelf first, or the
  /// server's `ABS_URL` points at a different Audiobookshelf.
  case unauthorized
  /// Something answered, but not a companion server (a pasted Audiobookshelf address, for one: its
  /// web app answers every unknown path with a 200 page).
  case notACompanion
  case unsupportedAPI(Int)
  case http(status: Int)
}

extension CompanionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidAddress:
      String(localized: "That doesn't look like a server address.", bundle: .module)
    case .unreachable:
      String(localized: "Couldn't reach that address from this device.", bundle: .module)
    case .unauthorized:
      String(localized: "The server refused this login. Sign in to Audiobookshelf first.", bundle: .module)
    case .notACompanion:
      String(localized: "Something answered at that address, but it isn't a companion server.", bundle: .module)
    case .unsupportedAPI(let version):
      String(localized: "This server speaks version \(version) of the API. Update the app.", bundle: .module)
    case .http(let status):
      String(localized: "The server returned HTTP \(status).", bundle: .module)
    }
  }
}

/// Where the companion configuration lives. UserDefaults, read synchronously, because clients are
/// built in stored-property initializers all over the app.
public enum CompanionSettings {
  static let daemonKey = "companion.daemonURL"
  static let workerOverrideKey = "companion.workerURL"
  static let capabilitiesKey = "companion.capabilities"
  static let seededKey = "companion.seeded"
  /// Set by builds before the connector existed (DEBUG launch args, in practice).
  static let legacyDaemonKey = "transcription.daemonURL"
  static let legacyWorkerKey = "transcription.workerURL"

  public static func daemonURL(in defaults: UserDefaults = .standard) -> URL? {
    defaults.string(forKey: daemonKey).flatMap(URL.init(string:))
  }

  /// A worker address typed by hand. Wins over the discovered one.
  public static func workerOverride(in defaults: UserDefaults = .standard) -> URL? {
    defaults.string(forKey: workerOverrideKey).flatMap(URL.init(string:))
  }

  public static func capabilities(in defaults: UserDefaults = .standard) -> CompanionCapabilities? {
    defaults.data(forKey: capabilitiesKey).flatMap {
      try? JSONDecoder().decode(CompanionCapabilities.self, from: $0)
    }
  }

  public static func endpoint(in defaults: UserDefaults = .standard) -> DaemonEndpoint? {
    guard let daemon = daemonURL(in: defaults) else { return nil }
    let worker = workerOverride(in: defaults) ?? capabilities(in: defaults)?.workerURL
    return DaemonEndpoint(daemon: daemon, worker: worker)
  }

  /// Whether a feature is available. A configured server that hasn't answered yet counts as having
  /// everything but the worker: calls to a missing feature fail quietly, while hiding features until
  /// the first answer would make them flicker on every install.
  public static func supports(
    _ feature: CompanionCapabilities.Feature,
    in defaults: UserDefaults = .standard
  ) -> Bool {
    guard daemonURL(in: defaults) != nil else { return false }
    let capabilities = capabilities(in: defaults)
    if feature == .jobs {
      if workerOverride(in: defaults) != nil { return true }
      return capabilities?.workerURL != nil && capabilities?.features.contains(.jobs) == true
    }
    return capabilities?.features.contains(feature) ?? true
  }

  public static func save(
    daemon: URL,
    capabilities: CompanionCapabilities?,
    in defaults: UserDefaults = .standard
  ) {
    defaults.set(daemon.absoluteString, forKey: daemonKey)
    if let data = capabilities.flatMap({ try? JSONEncoder().encode($0) }) {
      defaults.set(data, forKey: capabilitiesKey)
    } else {
      defaults.removeObject(forKey: capabilitiesKey)
    }
    defaults.set(true, forKey: seededKey)
  }

  public static func setWorkerOverride(_ worker: URL?, in defaults: UserDefaults = .standard) {
    defaults.set(worker?.absoluteString, forKey: workerOverrideKey)
  }

  /// Forget the server. The seed flag stays set, so a build-time default doesn't bring it back.
  public static func clear(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: daemonKey)
    defaults.removeObject(forKey: workerOverrideKey)
    defaults.removeObject(forKey: capabilitiesKey)
    defaults.set(true, forKey: seededKey)
  }

  /// First launch only: take the address from an older install, else from the build's defaults
  /// (`COMPANION_DAEMON_URL` in Local.xcconfig, usually empty). Later launches leave whatever the
  /// user chose alone, including having chosen nothing.
  public static func seedOnce(
    daemon: String?,
    worker: String?,
    in defaults: UserDefaults = .standard
  ) {
    guard !defaults.bool(forKey: seededKey) else { return }
    defaults.set(true, forKey: seededKey)
    guard defaults.string(forKey: daemonKey) == nil else { return }

    let legacyDaemon = defaults.string(forKey: legacyDaemonKey)
    let legacyWorker = defaults.string(forKey: legacyWorkerKey)
    defaults.removeObject(forKey: legacyDaemonKey)
    defaults.removeObject(forKey: legacyWorkerKey)

    guard let url = (legacyDaemon ?? daemon).flatMap(normalizedURL) else { return }
    defaults.set(url.absoluteString, forKey: daemonKey)
    if let worker = (legacyWorker ?? worker).flatMap(normalizedURL) {
      defaults.set(worker.absoluteString, forKey: workerOverrideKey)
    }
  }

  /// Turn what someone typed into a URL. With no scheme, a bare hostname means https and anything
  /// that looks local (an IP, a port, `.local`) means http, because that is how those get served.
  public static func normalizedURL(_ text: String) -> URL? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasScheme = trimmed.contains("://")
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

    if hasScheme {
      guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https", url.host?.isEmpty == false
      else { return nil }
      return url
    }

    let host = trimmed.split(separator: ":").first.map(String.init)?.split(separator: "/").first.map(String.init) ?? ""
    let isIP = host.allSatisfy { $0.isNumber || $0 == "." }
    let looksLocal = isIP || trimmed.contains(":") || host.hasSuffix(".local") || !host.contains(".")
    guard !host.isEmpty, let url = URL(string: (looksLocal ? "http://" : "https://") + trimmed), url.host != nil
    else { return nil }
    return url
  }
}

/// Asks a daemon what it offers.
public struct CompanionDiscovery: Sendable {
  private let session: URLSession
  private let authorization: AuthorizationProvider?

  /// The worker's stock port, for daemons that predate `/capabilities`.
  static let defaultWorkerPort = 8790

  public init(session: URLSession = .shared, authorization: AuthorizationProvider? = nil) {
    self.session = session
    self.authorization = authorization
  }

  public func discover(daemon: URL) async throws -> CompanionCapabilities {
    let (data, status) = try await get(daemon.appending(path: "capabilities"))
    switch status {
    case 200:
      guard let capabilities = try? JSONDecoder().decode(CompanionCapabilities.self, from: data) else {
        throw CompanionError.notACompanion
      }
      guard capabilities.api <= CompanionCapabilities.supportedAPI else {
        throw CompanionError.unsupportedAPI(capabilities.api)
      }
      return capabilities
    case 404:
      return try await probe(daemon: daemon)
    case 401, 403:
      throw CompanionError.unauthorized
    default:
      throw CompanionError.http(status: status)
    }
  }

  /// A daemon from before `/capabilities`: work out the same answer from routes it has always had.
  private func probe(daemon: URL) async throws -> CompanionCapabilities {
    struct Health: Decodable { let ok: Bool }
    struct State: Decodable { let state: String }

    let (health, healthStatus) = try await get(daemon.appending(path: "healthz"))
    guard healthStatus == 200, (try? JSONDecoder().decode(Health.self, from: health))?.ok == true else {
      throw CompanionError.notACompanion
    }

    var features: Set<CompanionCapabilities.Feature> = [.captions, .audio]
    if let (state, status) = try? await get(daemon.appending(path: "status")), status == 200,
      (try? JSONDecoder().decode(State.self, from: state)) != nil
    {
      features.insert(.speaker)
    }

    let worker = await probeWorker(daemon: daemon)
    if worker != nil { features.insert(.jobs) }
    return CompanionCapabilities(service: "abs-session", features: features, workerURL: worker)
  }

  /// Same host, the worker's port. Only works where the daemon is addressed by port; behind a
  /// hostname-per-service tunnel there is nothing to guess, and the worker needs `/capabilities`
  /// or a typed address.
  private func probeWorker(daemon: URL) async -> URL? {
    guard daemon.port != nil,
      var components = URLComponents(url: daemon, resolvingAgainstBaseURL: false)
    else { return nil }
    components.port = Self.defaultWorkerPort
    guard let guess = components.url,
      let (_, status) = try? await get(guess.appending(path: "healthz")), status == 200
    else { return nil }
    return guess
  }

  private func get(_ url: URL) async throws -> (Data, Int) {
    var request = URLRequest(url: url, timeoutInterval: 8)
    if let bearer = await authorization?() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw CompanionError.unreachable }
      return (data, http.statusCode)
    } catch is URLError {
      throw CompanionError.unreachable
    }
  }
}
