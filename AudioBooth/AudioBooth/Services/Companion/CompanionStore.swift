import API
import Foundation
import Transcription

// The companion server is optional, and only the personal build talks to one (FORK-NOTES "The two
// builds"). Everything that offers a server feature asks this store; docs/SELF-HOSTING.md is the
// other side of it.
#if SPEAKER_STACK

/// The one companion address and what it answered. The configuration itself lives in
/// `CompanionSettings`, which the Transcription package reads synchronously; this is the observable
/// face of it for SwiftUI.
@MainActor
@Observable
final class CompanionStore {
  static let shared = CompanionStore()

  private(set) var daemonURL: URL?
  private(set) var workerOverride: URL?
  private(set) var capabilities: CompanionCapabilities?
  /// Why the last refresh failed, for the settings screen. The last good answer stays in force.
  private(set) var lastRefreshError: String?

  private init() {
    reload()
  }

  /// Call once at launch, before anything builds a client: a fresh install takes its address from
  /// the build's `COMPANION_DAEMON_URL` / `COMPANION_WORKER_URL`, usually empty.
  static func bootstrap(bundle: Bundle = .main) {
    CompanionSettings.seedOnce(
      daemon: bundle.object(forInfoDictionaryKey: "AudioBoothCompanionURL") as? String,
      worker: bundle.object(forInfoDictionaryKey: "AudioBoothCompanionWorkerURL") as? String
    )
  }

  var isConfigured: Bool { daemonURL != nil }

  var supportsSpeaker: Bool { daemonURL != nil && CompanionSettings.supports(.speaker) }
  var supportsTranscripts: Bool { daemonURL != nil && CompanionSettings.supports(.captions) }
  var supportsServerJobs: Bool { daemonURL != nil && CompanionSettings.supports(.jobs) }

  /// Check an address, and keep it only if a companion server answers there.
  func connect(address: String, workerAddress: String) async throws {
    guard let url = CompanionSettings.normalizedURL(address) else { throw CompanionError.invalidAddress }
    let worker = workerAddress.isEmpty ? nil : CompanionSettings.normalizedURL(workerAddress)
    if !workerAddress.isEmpty, worker == nil { throw CompanionError.invalidAddress }

    let found = try await discovery.discover(daemon: url)
    if url != daemonURL { SpeakerSessionManager.shared.companionRemoved() }
    CompanionSettings.save(daemon: url, capabilities: found)
    CompanionSettings.setWorkerOverride(worker)
    lastRefreshError = nil
    reload()
  }

  /// Re-ask the server what it offers. Quiet: failing leaves the last answer in place, because a
  /// phone off its network is not a server that lost its speaker.
  func refresh() async {
    guard let daemonURL else { return }
    do {
      let found = try await discovery.discover(daemon: daemonURL)
      // The address may have changed while the request was out.
      guard self.daemonURL == daemonURL else { return }
      CompanionSettings.save(daemon: daemonURL, capabilities: found)
      lastRefreshError = nil
      reload()
    } catch {
      lastRefreshError = error.localizedDescription
    }
  }

  func disconnect() {
    SpeakerSessionManager.shared.companionRemoved()
    CompanionSettings.clear()
    lastRefreshError = nil
    reload()
  }

  private func reload() {
    daemonURL = CompanionSettings.daemonURL()
    workerOverride = CompanionSettings.workerOverride()
    capabilities = CompanionSettings.capabilities()
  }

  private var discovery: CompanionDiscovery {
    CompanionDiscovery(authorization: {
      guard let server = await Audiobookshelf.shared.authentication.server else { return nil }
      return try? await server.freshToken.bearer
    })
  }
}

#endif
