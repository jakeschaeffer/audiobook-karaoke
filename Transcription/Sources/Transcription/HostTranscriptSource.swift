import Foundation
import Logging

/// Where the companion server lives: the daemon, and the transcription worker if there is one.
///
/// Nothing about any particular deployment is compiled in. The user gives the app one daemon address
/// (Settings, or `COMPANION_DAEMON_URL` at build time) and the rest comes from the daemon's
/// `/capabilities`; see `CompanionSettings` and docs/COMPANION-API.md.
public struct DaemonEndpoint: Sendable {
  /// The daemon: library, tracks, captions, audio proxy, transport.
  public let daemon: URL
  /// The worker: transcription jobs and status. Optional on the server, so optional here.
  public let worker: URL?

  public init(daemon: URL, worker: URL? = nil) {
    self.daemon = daemon
    self.worker = worker
  }

  /// What clients get with no server configured. `.invalid` never resolves (RFC 2606), so a stray
  /// call fails like an unreachable server instead of going anywhere. Surfaces that offer a feature
  /// check `CompanionSettings.supports` first; this is only the floor under them.
  public static let unconfigured = DaemonEndpoint(daemon: URL(string: "http://companion.invalid")!)

  /// The configured server, or nil when there isn't one.
  public static var configured: DaemonEndpoint? { CompanionSettings.endpoint() }

  public static var current: DaemonEndpoint { configured ?? .unconfigured }
}

/// Supplies the `Authorization` header value (`"Bearer <token>"`) for a request, or nil for none.
///
/// The daemon and worker validate tokens against ABS itself, so the right provider hands over the
/// ABS session token the app already holds from login — there is no second credential. On the
/// LAN/tailnet the services don't require auth and a nil provider is fine; sending the header anyway
/// is harmless, so clients are constructed with the provider unconditionally.
public typealias AuthorizationProvider = @Sendable () async -> String?

/// Reads a book's transcript from the host worker via the daemon's `/captions`.
///
/// This is the first `TranscriptSource` conformance and, until the on-device engine is sized by the
/// device measurements, the only one. The host's output is also the *better* one — it runs
/// faster-whisper `small`, which beats Apple's `SpeechTranscriber` on WER — so this path is not a
/// stopgap.
public struct HostTranscriptSource: TranscriptSource {
  public let provenance: TranscriptProvenance = .hostRaw
  public let engineID: String
  private let endpoint: DaemonEndpoint
  private let session: URLSession
  private let logger = Logger(label: "transcription.host")

  /// Test seam: replaces the network fetch so the streaming/backfill logic is testable without a
  /// live daemon. Nil in production.
  var fetchOverride:
    (
      @Sendable (_ itemID: String, _ from: TimeInterval, _ to: TimeInterval) async throws
        -> [TranscriptSegment]
    )?

  /// How many grid chunks to request per HTTP round trip.
  ///
  /// A 20h book is ~243 chunks; fetching one window per chunk would be 243 requests, and fetching the
  /// whole book at once would decode ~2MB of JSON and ~23k segments in one go. Six chunks (30 min,
  /// ~580 segments) keeps both bounded.
  static let chunksPerRequest = 6

  private let authorization: AuthorizationProvider?

  public init(
    endpoint: DaemonEndpoint = .current,
    engineID: String = "faster-whisper/small",
    session: URLSession = .shared,
    authorization: AuthorizationProvider? = nil
  ) {
    self.endpoint = endpoint
    self.engineID = engineID
    self.session = session
    self.authorization = authorization
  }

  public func chunks(
    forItem itemID: String,
    indices: [Int]
  ) -> AsyncThrowingStream<TranscriptChunk, Error> {
    let wanted = indices.filter { $0 >= 0 }.sorted()
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          // Yielded so far, whether content or empty. `maxProduced` is the highest index that had
          // real segments anywhere in this call — the boundary between silence and absence.
          var handled = Set<Int>()
          var maxProduced = -1

          for run in Self.requestRuns(for: wanted, limit: Self.chunksPerRequest) {
            try Task.checkCancellation()
            guard let first = run.first, let last = run.last else { continue }

            // Fetch by time, then restrict bucketing to the indices we asked for. The daemon filters
            // on overlap, so this window can also return segments belonging to the chunks either side.
            let from = TranscriptGrid.range(of: first).lowerBound
            let to = TranscriptGrid.range(of: last).upperBound
            let segments = try await fetch(itemID: itemID, from: from, to: to)

            let built = TranscriptChunker.bucket(
              segments,
              itemID: itemID,
              provenance: provenance,
              engineID: engineID,
              restrictedTo: Set(run)
            )
            for chunk in built {
              handled.insert(chunk.chunkIndex)
              maxProduced = max(maxProduced, chunk.chunkIndex)
              continuation.yield(chunk)
            }

            // A requested index with no segments is a real, coverable outcome — a stretch of silence
            // still gets a row, or the scheduler would ask for it forever. Silence is only
            // distinguishable from absence by position: anything below the highest content chunk seen
            // *in this whole call* is interior silence; anything past it is absence (a transcript that
            // ends early) and must stay uncovered so the job UI can offer to resume. The boundary is
            // call-scoped, not window-scoped — a silent chunk at a window seam whose next content
            // lands in the following window still gets its row.
            for index in wanted where index < maxProduced && !handled.contains(index) {
              handled.insert(index)
              continuation.yield(
                TranscriptChunk(
                  itemID: itemID,
                  chunkIndex: index,
                  segments: [],
                  provenance: provenance,
                  engineID: engineID
                )
              )
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Split sorted indices into contiguous runs of at most `limit`.
  ///
  /// A run maps to one `/captions` request spanning exactly the runs's chunks. Splitting on gaps
  /// matters: slicing the sorted array without it would turn a disjoint request like `[0, 1, 240]`
  /// into a single fetch from 0s to 72,300s — the entire book — only to discard all but three chunks.
  /// Disjoint requests are exactly what a JIT scheduler produces after a seek, so this is load-bearing
  /// for the engine path, not an optimization.
  static func requestRuns(for indices: [Int], limit: Int) -> [[Int]] {
    var runs: [[Int]] = []
    var current: [Int] = []
    for index in indices {
      if let previous = current.last {
        if index == previous { continue }  // tolerate duplicates
        if index != previous + 1 || current.count == limit {
          runs.append(current)
          current = []
        }
      }
      current.append(index)
    }
    if !current.isEmpty { runs.append(current) }
    return runs
  }

  private func fetch(
    itemID: String,
    from: TimeInterval,
    to: TimeInterval
  ) async throws -> [TranscriptSegment] {
    if let fetchOverride {
      return try await fetchOverride(itemID, from, to)
    }
    return try await captions(itemID: itemID, from: from, to: to)
  }

  /// Source-compat for the transition: `TrackInfo` is a top-level engine type now (see
  /// `TrackInfo.swift`); the daemon's compact wire keys map into it privately below.
  public typealias TrackInfo = Transcription.TrackInfo

  /// `GET /tracks?item_id` — the book's track map.
  public func tracks(forItem itemID: String) async throws -> [TrackInfo] {
    var components = URLComponents(
      url: endpoint.daemon.appending(path: "tracks"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [.init(name: "item_id", value: itemID)]
    guard let url = components.url else { throw TranscriptionError.badURL }

    var request = URLRequest(url: url)
    if let bearer = await authorization?() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard http.statusCode == 200 else { throw TranscriptionError.http(status: http.statusCode) }
    return try Self.decodeTracks(data)
  }

  /// Split out for tests, like `WorkerClient.decodeStatus`: the daemon's compact wire keys
  /// (`i`/`start`/`dur`) map into the engine's `TrackInfo` here and nowhere else.
  static func decodeTracks(_ data: Data) throws -> [TrackInfo] {
    struct TrackWire: Decodable {
      let i: Int
      let start: TimeInterval
      let dur: TimeInterval
    }
    struct TracksResponse: Decodable {
      let tracks: [TrackWire]
    }
    return try JSONDecoder().decode(TracksResponse.self, from: data).tracks
      .map { TrackInfo(index: $0.i, start: $0.start, duration: $0.dur) }
  }

  /// `GET /audio?item_id&track=N` — download one track's audio to a temporary file. The proxy
  /// injects the ABS token server-side; ours rides along for the tunnel middleware.
  ///
  /// The saved file's extension comes from the actual container (sniffed bytes first, then the
  /// proxied `Content-Type`), because `AVAudioFile` treats the extension as its file-type hint and
  /// a wrong hint fails the open outright — an `.m4b` book saved as `.mp3` dies with
  /// `kAudioFileInvalidFileError` before a single sample is read.
  public func downloadAudio(forItem itemID: String, track: Int) async throws -> URL {
    var components = URLComponents(
      url: endpoint.daemon.appending(path: "audio"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      .init(name: "item_id", value: itemID),
      .init(name: "track", value: String(track)),
    ]
    guard let url = components.url else { throw TranscriptionError.badURL }

    var request = URLRequest(url: url)
    if let bearer = await authorization?() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (temporary, response) = try await session.download(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      try? FileManager.default.removeItem(at: temporary)
      throw TranscriptionError.badResponse
    }

    let header = (try? FileHandle(forReadingFrom: temporary)).map { handle in
      defer { try? handle.close() }
      return (try? handle.read(upToCount: 12)) ?? Data()
    }
    let ext =
      AudioFileType.fileExtension(sniffing: header ?? Data())
      ?? AudioFileType.fileExtension(forContentType: http.value(forHTTPHeaderField: "Content-Type"))
      ?? "mp3"
    guard AudioFileType.isCoreAudioReadable(ext) else {
      try? FileManager.default.removeItem(at: temporary)
      throw TranscriptionError.unsupportedAudioFormat(container: ext)
    }

    let destination = FileManager.default.temporaryDirectory
      .appending(path: "transcribe-\(itemID)-\(track).\(ext)")
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  /// `GET /captions?item_id&from&to&words=1` — segments in a book-absolute window.
  func captions(
    itemID: String,
    from: TimeInterval,
    to: TimeInterval,
    words: Bool = true
  ) async throws -> [TranscriptSegment] {
    var components = URLComponents(
      url: endpoint.daemon.appending(path: "captions"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      .init(name: "item_id", value: itemID),
      .init(name: "from", value: String(from)),
      .init(name: "to", value: String(to)),
      .init(name: "words", value: words ? "1" : "0"),
    ]
    guard let url = components.url else { throw TranscriptionError.badURL }

    var request = URLRequest(url: url)
    if let bearer = await authorization?() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
    guard http.statusCode == 200 else {
      // 404 is "this item has no transcript at all" — ordinary for most of the library, and the signal
      // callers use to stop retrying until the worker reports new coverage. A *partial* transcript
      // returns 200 with whatever it has, so this never fires mid-book.
      if http.statusCode == 404 { throw TranscriptionError.noTranscript }
      throw TranscriptionError.http(status: http.statusCode)
    }
    return try JSONDecoder().decode(CaptionsResponse.self, from: data).segments
  }

  private struct CaptionsResponse: Decodable {
    let segments: [TranscriptSegment]
  }
}

public enum TranscriptionError: Error, Equatable {
  case badURL
  case badResponse
  case http(status: Int)
  /// The item has no transcript on the host at all (`/captions` 404). Distinct from a partial
  /// transcript, which returns 200 with what exists.
  case noTranscript
  /// The item has no audio (`duration == 0`), so there is nothing to transcribe. 31 of this library's
  /// 48 items are ebook-only; offering transcription for them already caused one real bug server-side.
  case itemHasNoAudio
  /// The track's container (e.g. ogg/opus) has no Core Audio reader on iOS, so on-device
  /// transcription can never open it. The host worker's ffmpeg can — the recoverable path is
  /// "Transcribe on Server", and the message must say so rather than leak an OSStatus.
  case unsupportedAudioFormat(container: String)
  /// `AVAudioFile` refused a container we expected to be readable. Carries the underlying error
  /// text because this is the case we *can't* explain in advance.
  case audioOpenFailed(detail: String)
  /// `ProcessInfo.thermalState` hit `.critical` mid-run; the session stops rather than cook the
  /// phone. Committed tracks persist, so a later run resumes from coverage.
  case deviceTooHot
  /// The on-device foundation model isn't available (Apple Intelligence off, ineligible hardware,
  /// or model not yet downloaded). Ordinary, not exceptional — callers hide cleanup entirely.
  case cleanupUnavailable
  /// The audio provider only serves local files and this book isn't downloaded. Recoverable by
  /// downloading the book (or, in setups with a server provider, automatically composed around).
  case audioNotDownloaded
}

extension TranscriptionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .badURL:
      String(localized: "Bad request URL.", bundle: .module)
    case .badResponse:
      String(localized: "The transcript service gave an unexpected response.", bundle: .module)
    case .http(let status):
      String(localized: "The transcript service returned HTTP \(status).", bundle: .module)
    case .noTranscript:
      String(localized: "No transcript exists for this book yet.", bundle: .module)
    case .itemHasNoAudio:
      String(localized: "This item has no audio to transcribe.", bundle: .module)
    case .unsupportedAudioFormat(let container):
      String(
        localized:
          "This book's audio is \(container.uppercased()), which iPhone transcription can't read. Use Transcribe on Server instead.",
        bundle: .module
      )
    case .audioOpenFailed(let detail):
      String(localized: "Couldn't read this book's audio file (\(detail)).", bundle: .module)
    case .deviceTooHot:
      String(
        localized:
          "iPhone got too hot — transcription stopped. Finished tracks are kept; run again to resume.",
        bundle: .module
      )
    case .cleanupUnavailable:
      String(
        localized: "Text cleanup needs Apple Intelligence, which isn't available on this device.",
        bundle: .module
      )
    case .audioNotDownloaded:
      String(localized: "Download this book to transcribe it on iPhone.", bundle: .module)
    }
  }
}
