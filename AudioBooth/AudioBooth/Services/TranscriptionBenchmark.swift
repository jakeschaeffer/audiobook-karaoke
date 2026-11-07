#if DEBUG
import API
import AVFoundation
import Foundation
import Speech
import Transcription
import UIKit

/// Track A, experiment 2 (IOS-SPEC §Measure before building): SpeechTranscriber throughput on
/// this device, foreground, with WWDC-277's *concurrent* drain of `transcriber.results`.
///
/// The one published iPhone 17 Pro Max number (4.6–6.2x realtime) came from a run whose phase
/// split implies a serial drain — results collected after analysis instead of alongside it — and
/// is implausible against ~70x for the same model on an M4. This measures our hardware with the
/// concurrent pattern and decides whether the JIT engine's headroom budget is 5x or 30x.
///
/// Runs track-by-track (Goblet's tracks are 18–28 min), logging wall-clock, realtime factor, and
/// `thermalState` per track so thermal drift across a sustained run is visible. Audio comes from
/// the daemon's `/audio` proxy using the app's normal endpoint + ABS auth. Results go to `print`
/// for `devicectl … launch --console` capture.
///
///     xcrun devicectl device process launch --console --device <id> \
///       <bundle id> -transcribeBench 45
@available(iOS 26.0, *)
enum TranscriptionBenchmark {
  /// Harry Potter and the Goblet of Fire — fully transcribed on the host, so host-vs-device
  /// output can also be compared later.
  private static let itemID = "f4f72906-0548-45b2-b75a-44d08826e458"

  /// Results go to a file as well as stdout: devicectl's console pipe buffers aggressively enough
  /// to sit at zero bytes through a whole run, but the app container is pullable over USB at any
  /// time (`devicectl device copy from … --domain-type appDataContainer`).
  private static let logURL = URL.documentsDirectory.appending(path: "experiment2.log")

  private static func report(_ line: String) {
    print(line)
    let stamped = "\(Date().formatted(.iso8601))  \(line)\n"
    if let data = stamped.data(using: .utf8) {
      if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: logURL)
      }
    }
  }

  static func runIfRequested() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-transcribeBench"), index + 1 < arguments.count,
      let minutes = Int(arguments[index + 1]), minutes > 0
    else { return }

    Task.detached(priority: .userInitiated) {
      await MainActor.run { ScreenWakeCoordinator.shared.acquire("benchmark") }
      await run(targetMinutes: minutes)
      await MainActor.run { ScreenWakeCoordinator.shared.release("benchmark") }
    }
  }

  private static func run(targetMinutes: Int) async {
    await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = true }
    let charging = await MainActor.run { UIDevice.current.batteryState != .unplugged }
    report(
      "EXPERIMENT-2 start target=\(targetMinutes)min charging=\(charging) "
        + "thermal=\(thermalName)"
    )

    do {
      let tracks = try await pickTracks(totalSeconds: Double(targetMinutes) * 60)
      report("EXPERIMENT-2 plan: \(tracks.map { "track \($0.index) (\(Int($0.duration))s)" }.joined(separator: ", "))")

      var totalAudio = 0.0
      var totalWall = 0.0
      for track in tracks {
        let url = try await download(track: track.index)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let audioSeconds = Double(file.length) / file.processingFormat.sampleRate

        let transcriber = SpeechTranscriber(
          locale: Locale(identifier: "en-US"),
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(
          supporting: [transcriber])
        {
          report("EXPERIMENT-2 downloading speech assets…")
          try await installation.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let started = Date()
        // The load-bearing detail: drain results CONCURRENTLY with analysis. A serial drain is
        // exactly the suspected flaw in the published 5x figure.
        async let collected = collect(from: transcriber)
        let lastSample = try await analyzer.analyzeSequence(from: file)
        if let lastSample {
          try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
          await analyzer.cancelAndFinishNow()
        }
        let (results, characters, sawWordTimings) = try await collected
        let wall = Date().timeIntervalSince(started)

        totalAudio += audioSeconds
        totalWall += wall
        report(
          "EXPERIMENT-2 track=\(track.index) audio=\(Int(audioSeconds))s wall=\(String(format: "%.1f", wall))s "
            + "rtf=\(String(format: "%.1f", audioSeconds / max(wall, 0.001))) results=\(results) "
            + "chars=\(characters) wordTimings=\(sawWordTimings) thermal=\(thermalName)"
        )
      }

      report(
        "EXPERIMENT-2 TOTAL audio=\(Int(totalAudio))s wall=\(String(format: "%.1f", totalWall))s "
          + "rtf=\(String(format: "%.2f", totalAudio / max(totalWall, 0.001))) thermalEnd=\(thermalName)"
      )
    } catch {
      report("EXPERIMENT-2 FAILED: \(error)")
    }
  }

  private static func collect(
    from transcriber: SpeechTranscriber
  ) async throws -> (results: Int, characters: Int, sawWordTimings: Bool) {
    var results = 0
    var characters = 0
    var sawWordTimings = false
    for try await result in transcriber.results {
      results += 1
      characters += result.text.characters.count
      if !sawWordTimings {
        // API-shape validation for the karaoke pipeline: are audioTimeRange attributes
        // present at run granularity in real output?
        sawWordTimings = result.text.runs[\.audioTimeRange].contains { range, _ in range != nil }
      }
    }
    return (results, characters, sawWordTimings)
  }

  private static var thermalName: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }

  // MARK: - Audio from the daemon

  private struct Track {
    let index: Int
    let duration: Double
  }

  private static let authorization: AuthorizationProvider = {
    guard let server = Audiobookshelf.shared.authentication.server else { return nil }
    return try? await server.freshToken.bearer
  }

  /// Consecutive tracks (skipping the 63s intro track) totalling at least `totalSeconds`.
  private static func pickTracks(totalSeconds: Double) async throws -> [Track] {
    var request = URLRequest(
      url: DaemonEndpoint.current.daemon.appending(path: "tracks")
        .appending(queryItems: [.init(name: "item_id", value: itemID)])
    )
    if let bearer = await authorization() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (data, _) = try await URLSession.shared.data(for: request)
    struct TracksResponse: Decodable {
      struct Entry: Decodable {
        let i: Int
        let dur: Double
      }
      let tracks: [Entry]
    }
    let all = try JSONDecoder().decode(TracksResponse.self, from: data).tracks
    var picked: [Track] = []
    var sum = 0.0
    for entry in all where entry.dur > 120 {
      picked.append(Track(index: entry.i, duration: entry.dur))
      sum += entry.dur
      if sum >= totalSeconds { break }
    }
    return picked
  }

  private static func download(track: Int) async throws -> URL {
    var request = URLRequest(
      url: DaemonEndpoint.current.daemon.appending(path: "audio")
        .appending(queryItems: [
          .init(name: "item_id", value: itemID),
          .init(name: "track", value: String(track)),
        ])
    )
    if let bearer = await authorization() {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }
    let (temp, response) = try await URLSession.shared.download(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw TranscriptionError.badResponse
    }
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "bench-track-\(track).mp3")
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: temp, to: destination)
    return destination
  }
}
#endif
