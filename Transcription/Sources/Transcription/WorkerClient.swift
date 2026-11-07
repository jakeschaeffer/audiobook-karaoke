import Foundation

/// One transcription job on the abs-caption-worker, as its API reports it.
///
/// `pct`, `rtf`, and `eta_secs` come from the live rate, so they are honest under throttling or after
/// a resume. `eta_secs` is null unless the job is actually running. Jobs are idempotent per item —
/// re-requesting an item with a live job returns the existing one — and resumable at track
/// granularity, so a cancel or a host reboot costs at most the current track.
public struct TranscriptionJob: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case queued, running, done, error, cancelled
  }

  public let id: String
  public let itemID: String
  public let state: State
  /// 0–100, from audio seconds done vs total.
  public let pct: Double?
  /// Realtime factor of the live run (host measures ~4.6x on this library).
  public let rtf: Double?
  public let etaSecs: Double?
  public let error: String?

  public var isActive: Bool {
    state == .queued || state == .running
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case itemID = "item_id"
    case state
    case pct
    case rtf
    case etaSecs = "eta_secs"
    case error
  }

  public init(
    id: String,
    itemID: String,
    state: State,
    pct: Double? = nil,
    rtf: Double? = nil,
    etaSecs: Double? = nil,
    error: String? = nil
  ) {
    self.id = id
    self.itemID = itemID
    self.state = state
    self.pct = pct
    self.rtf = rtf
    self.etaSecs = etaSecs
    self.error = error
  }
}

/// The worker's whole view of one item: host-side coverage plus the latest job, live or past.
public struct WorkerStatus: Equatable, Sendable {
  public let coverage: RemoteCoverage
  public let job: TranscriptionJob?

  public init(coverage: RemoteCoverage, job: TranscriptionJob?) {
    self.coverage = coverage
    self.job = job
  }
}

/// Client for the caption worker.
///
/// Read paths are safe to poll; `requestTranscription` starts a real multi-hour CPU job on the host
/// and must only ever run from an explicit user action.
public struct WorkerClient: Sendable {
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

  private func workerURL() throws -> URL {
    guard let worker = endpoint.worker else { throw TranscriptionError.badURL }
    return worker
  }

  /// `GET /status?item_id` — coverage watermark plus the newest job for the item.
  public func status(itemID: String) async throws -> WorkerStatus {
    var components = URLComponents(
      url: try workerURL().appending(path: "status"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [.init(name: "item_id", value: itemID)]
    guard let url = components.url else { throw TranscriptionError.badURL }

    let (data, response) = try await session.data(for: authorized(URLRequest(url: url)))
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard http.statusCode == 200 else { throw TranscriptionError.http(status: http.statusCode) }
    return try Self.decodeStatus(data)
  }

  /// `POST /jobs` — start (or resume) transcribing an item. 202 with the job, which may be an
  /// already-live one since jobs are idempotent per item.
  @discardableResult
  public func requestTranscription(itemID: String) async throws -> TranscriptionJob {
    var request = URLRequest(url: try workerURL().appending(path: "jobs"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["item_id": itemID])

    let (data, response) = try await session.data(for: authorized(request))
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard (200...202).contains(http.statusCode) else {
      throw TranscriptionError.http(status: http.statusCode)
    }
    return try JSONDecoder().decode(TranscriptionJob.self, from: data)
  }

  /// `DELETE /jobs/{id}` — cancel. The partial transcript survives; a later request resumes from the
  /// last finished track.
  public func cancel(jobID: String) async throws {
    var request = URLRequest(url: try workerURL().appending(path: "jobs").appending(path: jobID))
    request.httpMethod = "DELETE"
    let (_, response) = try await session.data(for: authorized(request))
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard (200...204).contains(http.statusCode) else {
      throw TranscriptionError.http(status: http.statusCode)
    }
  }

  /// `PUT /transcripts/{item_id}` — store a client-produced transcript on the host, where
  /// `/captions` immediately serves it to every other client. Write-once *per provenance tier*
  /// server-side: the `X-Transcript-Provenance` header lets a strictly higher tier replace an
  /// existing transcript, anything else is 409. Returns `false` on 409 (benign — the server
  /// already holds same-or-better), `true` when this upload became the transcript of record.
  /// Servers predating provenance versioning ignore the header and keep pure write-once.
  @discardableResult
  public func uploadTranscript(
    itemID: String,
    jsonl: Data,
    provenance: TranscriptProvenance? = nil
  ) async throws -> Bool {
    var request = URLRequest(
      url: try workerURL().appending(path: "transcripts").appending(path: itemID)
    )
    request.httpMethod = "PUT"
    request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
    if let provenance {
      request.setValue(provenance.rawValue, forHTTPHeaderField: "X-Transcript-Provenance")
    }
    request.httpBody = jsonl

    let (_, response) = try await session.data(for: authorized(request))
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    switch http.statusCode {
    case 201: return true
    case 409: return false
    default: throw TranscriptionError.http(status: http.statusCode)
    }
  }

  private func authorized(_ request: URLRequest) async -> URLRequest {
    guard let bearer = await authorization?() else { return request }
    var request = request
    request.setValue(bearer, forHTTPHeaderField: "Authorization")
    return request
  }

  /// Split out for tests: the wire has nullable `segments`/`covered_secs` (both null when no
  /// transcript exists, as verified live against an untranscribed item), which must land as zeros,
  /// not decode failures.
  static func decodeStatus(_ data: Data) throws -> WorkerStatus {
    let wire = try JSONDecoder().decode(StatusWire.self, from: data)
    return WorkerStatus(
      coverage: RemoteCoverage(
        hasTranscript: wire.hasTranscript,
        segments: wire.segments ?? 0,
        coveredSecs: wire.coveredSecs ?? 0,
        // Absent from pre-versioning servers and unknown strings from future ones both land as
        // nil — "tier unknown", which callers must treat as "assume upload is worthwhile".
        provenance: wire.provenance.flatMap(TranscriptProvenance.init(rawValue:))
      ),
      job: wire.job
    )
  }

  private struct StatusWire: Decodable {
    let hasTranscript: Bool
    let segments: Int?
    let coveredSecs: Double?
    let provenance: String?
    let job: TranscriptionJob?

    enum CodingKeys: String, CodingKey {
      case hasTranscript = "has_transcript"
      case segments
      case coveredSecs = "covered_secs"
      case provenance
      case job
    }
  }
}
