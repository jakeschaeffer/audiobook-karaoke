import Foundation

/// Fork-only daemon glue, kept in one file on purpose: this is where the portable engine seams
/// (`TranscriptionAudioProvider`, `RemoteTranscriptService`) meet the personal abs-session
/// daemon/worker. An upstream distribution of this package is the same source tree minus this
/// file and the daemon clients it wraps (`HostTranscriptSource`, `WorkerClient`,
/// `RemoteTransport`, `DaemonEventsSocket`).

/// `RemoteTranscriptService` plus job orchestration — the daemon's worker can be *asked* to
/// transcribe server-side and polled for progress. Job ops are a property of this server, not of
/// remote transcript stores in general, which is why they live here and not on the base protocol.
public protocol RemoteTranscriptionJobService: RemoteTranscriptService {
  func status(forItem itemID: String) async throws -> WorkerStatus
  @discardableResult
  func requestTranscription(forItem itemID: String) async throws -> TranscriptionJob
  func cancelJob(id: String) async throws
}

/// The abs-session daemon + worker as one `RemoteTranscriptionJobService`.
public struct DaemonRemoteService: RemoteTranscriptionJobService {
  private let host: HostTranscriptSource
  private let worker: WorkerClient
  private let hasWorker: Bool

  public init(endpoint: DaemonEndpoint = .current, authorization: AuthorizationProvider? = nil) {
    host = HostTranscriptSource(endpoint: endpoint, authorization: authorization)
    worker = WorkerClient(endpoint: endpoint, authorization: authorization)
    hasWorker = endpoint.worker != nil
  }

  public var source: (any TranscriptSource)? { host }

  public func bestProvenance(forItem itemID: String) async -> TranscriptProvenance? {
    (try? await worker.status(itemID: itemID))?.coverage.provenance
  }

  @discardableResult
  public func upload(
    itemID: String,
    jsonl: Data,
    provenance: TranscriptProvenance
  ) async throws -> Bool {
    // Uploading is opportunistic: a server with no worker just has nowhere to keep a phone's work.
    guard hasWorker else { return false }
    return try await worker.uploadTranscript(itemID: itemID, jsonl: jsonl, provenance: provenance)
  }

  public func status(forItem itemID: String) async throws -> WorkerStatus {
    try await worker.status(itemID: itemID)
  }

  @discardableResult
  public func requestTranscription(forItem itemID: String) async throws -> TranscriptionJob {
    try await worker.requestTranscription(itemID: itemID)
  }

  public func cancelJob(id: String) async throws {
    try await worker.cancel(jobID: id)
  }
}

/// The daemon as an audio source: `/tracks` and the token-injecting `/audio` proxy. Serves books
/// that aren't downloaded to the phone; the app composes it behind local files.
extension HostTranscriptSource: TranscriptionAudioProvider {
  public func audio(forItem itemID: String, track: TrackInfo) async throws -> TranscriptionAudio {
    TranscriptionAudio(
      url: try await downloadAudio(forItem: itemID, track: track.index),
      isTemporary: true
    )
  }
}
