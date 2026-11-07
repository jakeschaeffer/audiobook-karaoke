import Foundation
import Testing

@testable import Transcription

extension DaemonEndpoint {
  /// The server the opt-in live suites talk to (`TRANSCRIPTION_LIVE=1`), from the environment:
  /// `COMPANION_DAEMON_URL`, `COMPANION_WORKER_URL`.
  static var live: DaemonEndpoint {
    let environment = ProcessInfo.processInfo.environment
    guard let daemon = environment["COMPANION_DAEMON_URL"].flatMap(URL.init(string:)) else {
      return .unconfigured
    }
    return DaemonEndpoint(daemon: daemon, worker: environment["COMPANION_WORKER_URL"].flatMap(URL.init(string:)))
  }
}

private func freshDefaults(_ name: String = #function) -> UserDefaults {
  let suite = "companion-tests-\(name)-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Suite("Companion addresses")
struct CompanionAddressTests {
  @Test(arguments: [
    ("captions.example.com", "https://captions.example.com"),
    ("  https://captions.example.com/  ", "https://captions.example.com"),
    ("192.168.1.5:8788", "http://192.168.1.5:8788"),
    ("100.64.0.1", "http://100.64.0.1"),
    ("nas:8788", "http://nas:8788"),
    ("nas.local", "http://nas.local"),
    ("example.com:8788", "http://example.com:8788"),
    ("http://nas.example.com:8788", "http://nas.example.com:8788"),
  ])
  func normalizes(input: String, expected: String) {
    #expect(CompanionSettings.normalizedURL(input)?.absoluteString == expected)
  }

  @Test(arguments: ["", "   ", "not a url", "ftp://example.com", "https://"])
  func rejects(input: String) {
    #expect(CompanionSettings.normalizedURL(input) == nil)
  }
}

@Suite("Companion settings")
struct CompanionSettingsTests {
  @Test func nothingConfiguredMeansNoFeatures() {
    let defaults = freshDefaults()
    #expect(CompanionSettings.endpoint(in: defaults) == nil)
    for feature in CompanionCapabilities.Feature.allCases {
      #expect(!CompanionSettings.supports(feature, in: defaults))
    }
  }

  @Test func capabilitiesDecideFeaturesAndWorker() {
    let defaults = freshDefaults()
    let daemon = URL(string: "https://d.example.com")!
    let worker = URL(string: "https://w.example.com")!
    CompanionSettings.save(
      daemon: daemon,
      capabilities: CompanionCapabilities(features: [.captions, .jobs], workerURL: worker),
      in: defaults
    )
    #expect(CompanionSettings.supports(.captions, in: defaults))
    #expect(!CompanionSettings.supports(.speaker, in: defaults))
    #expect(CompanionSettings.supports(.jobs, in: defaults))
    #expect(CompanionSettings.endpoint(in: defaults)?.worker == worker)
  }

  @Test func unansweredServerOffersEverythingButJobs() {
    let defaults = freshDefaults()
    CompanionSettings.save(daemon: URL(string: "https://d.example.com")!, capabilities: nil, in: defaults)
    #expect(CompanionSettings.supports(.speaker, in: defaults))
    #expect(CompanionSettings.supports(.captions, in: defaults))
    #expect(!CompanionSettings.supports(.jobs, in: defaults))
  }

  @Test func typedWorkerBeatsDiscovered() {
    let defaults = freshDefaults()
    let typed = URL(string: "https://typed.example.com")!
    CompanionSettings.save(
      daemon: URL(string: "https://d.example.com")!,
      capabilities: CompanionCapabilities(features: [.captions], workerURL: URL(string: "https://w.example.com")!),
      in: defaults
    )
    CompanionSettings.setWorkerOverride(typed, in: defaults)
    #expect(CompanionSettings.endpoint(in: defaults)?.worker == typed)
    #expect(CompanionSettings.supports(.jobs, in: defaults))
  }

  @Test func seedAppliesOnceAndNeverRevivesARemovedServer() {
    let defaults = freshDefaults()
    CompanionSettings.seedOnce(daemon: "captions.example.com", worker: "jobs.example.com", in: defaults)
    #expect(CompanionSettings.daemonURL(in: defaults)?.absoluteString == "https://captions.example.com")
    #expect(CompanionSettings.workerOverride(in: defaults)?.absoluteString == "https://jobs.example.com")

    CompanionSettings.clear(in: defaults)
    CompanionSettings.seedOnce(daemon: "captions.example.com", worker: nil, in: defaults)
    #expect(CompanionSettings.daemonURL(in: defaults) == nil)
  }

  @Test func emptySeedLeavesTheAppUnconfigured() {
    let defaults = freshDefaults()
    CompanionSettings.seedOnce(daemon: "", worker: "", in: defaults)
    #expect(CompanionSettings.endpoint(in: defaults) == nil)
  }

  @Test func olderInstallsKeepTheirAddress() {
    let defaults = freshDefaults()
    defaults.set("http://10.0.0.2:8788", forKey: CompanionSettings.legacyDaemonKey)
    defaults.set("http://10.0.0.2:8790", forKey: CompanionSettings.legacyWorkerKey)
    CompanionSettings.seedOnce(daemon: "captions.example.com", worker: nil, in: defaults)
    #expect(CompanionSettings.daemonURL(in: defaults)?.absoluteString == "http://10.0.0.2:8788")
    #expect(CompanionSettings.workerOverride(in: defaults)?.absoluteString == "http://10.0.0.2:8790")
    #expect(defaults.string(forKey: CompanionSettings.legacyDaemonKey) == nil)
  }
}

@Suite("Companion capabilities wire format")
struct CompanionWireTests {
  @Test func decodesTheContract() throws {
    let json = #"""
      {"service": "abs-session", "api": 1,
       "features": ["captions", "audio", "speaker", "jobs", "something-new"],
       "worker_url": "https://jobs.example.com",
       "speaker": {"name": "Kitchen", "kind": "wiim"}}
      """#
    let decoded = try JSONDecoder().decode(CompanionCapabilities.self, from: Data(json.utf8))
    #expect(decoded.features == [.captions, .audio, .speaker, .jobs])
    #expect(decoded.workerURL?.absoluteString == "https://jobs.example.com")
    #expect(decoded.speakerName == "Kitchen")
  }

  @Test func minimalServerIsValid() throws {
    let json = #"{"api": 1, "features": ["captions"], "worker_url": null}"#
    let decoded = try JSONDecoder().decode(CompanionCapabilities.self, from: Data(json.utf8))
    #expect(decoded.features == [.captions])
    #expect(decoded.workerURL == nil)
    #expect(decoded.speakerName == nil)
  }

  @Test func roundTripsThroughStorage() throws {
    let original = CompanionCapabilities(
      service: "abs-session",
      features: [.speaker, .captions],
      workerURL: URL(string: "https://w.example.com"),
      speakerName: "Den"
    )
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(CompanionCapabilities.self, from: data) == original)
  }
}

/// Answers by path; a global because URLProtocol is instantiated by the system.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
  nonisolated(unsafe) static var seenAuthorization: String?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    Self.seenAuthorization = request.value(forHTTPHeaderField: "Authorization")
    let key = "\(request.url?.host() ?? ""):\(request.url?.port ?? 0)\(request.url?.path() ?? "")"
    guard let (status, body) = Self.routes[key] else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Suite("Companion discovery", .serialized)
struct CompanionDiscoveryTests {
  private func discovery(_ routes: [String: (Int, String)]) -> CompanionDiscovery {
    StubProtocol.routes = routes
    StubProtocol.seenAuthorization = nil
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return CompanionDiscovery(session: URLSession(configuration: configuration), authorization: { "Bearer abc" })
  }

  private let daemon = URL(string: "http://nas:8788")!

  @Test func readsCapabilitiesAndSendsTheLogin() async throws {
    let found = try await discovery([
      "nas:8788/capabilities": (200, #"{"api":1,"features":["captions","speaker"],"worker_url":null}"#)
    ]).discover(daemon: daemon)
    #expect(found.features == [.captions, .speaker])
    #expect(StubProtocol.seenAuthorization == "Bearer abc")
  }

  @Test func olderDaemonIsProbed() async throws {
    let found = try await discovery([
      "nas:8788/capabilities": (404, "not found"),
      "nas:8788/healthz": (200, #"{"ok": true}"#),
      "nas:8788/status": (200, #"{"state": "idle", "wiim_host": "x"}"#),
      "nas:8790/healthz": (200, #"{"ok": true}"#),
    ]).discover(daemon: daemon)
    #expect(found.features == [.captions, .audio, .speaker, .jobs])
    #expect(found.workerURL?.absoluteString == "http://nas:8790")
  }

  @Test func probeWithoutWorkerOffersNoJobs() async throws {
    let found = try await discovery([
      "nas:8788/capabilities": (404, "not found"),
      "nas:8788/healthz": (200, #"{"ok": true}"#),
      "nas:8788/status": (200, #"{"state": "idle"}"#),
    ]).discover(daemon: daemon)
    #expect(!found.features.contains(.jobs))
    #expect(found.workerURL == nil)
  }

  @Test func audiobookshelfAddressIsNotACompanion() async {
    // Its web app answers every unknown path with 200 and a page.
    await #expect(throws: CompanionError.notACompanion) {
      try await discovery(["nas:8788/capabilities": (200, "<!DOCTYPE html><html></html>")]).discover(daemon: daemon)
    }
  }

  @Test func unrelatedServerIsNotACompanion() async {
    await #expect(throws: CompanionError.notACompanion) {
      try await discovery(["nas:8788/capabilities": (404, "nope"), "nas:8788/healthz": (404, "nope")]).discover(
        daemon: daemon
      )
    }
  }

  @Test func refusedLoginIsReported() async {
    await #expect(throws: CompanionError.unauthorized) {
      try await discovery(["nas:8788/capabilities": (401, #"{"error":"unauthorized"}"#)]).discover(daemon: daemon)
    }
  }

  @Test func newerContractIsReported() async {
    await #expect(throws: CompanionError.unsupportedAPI(2)) {
      try await discovery(["nas:8788/capabilities": (200, #"{"api":2,"features":[]}"#)]).discover(daemon: daemon)
    }
  }

  @Test func unreachableIsReported() async {
    await #expect(throws: CompanionError.unreachable) {
      try await discovery([:]).discover(daemon: daemon)
    }
  }
}
