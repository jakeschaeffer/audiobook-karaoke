import Foundation
import Logging

/// Subscribes to the daemon's `WS /events`: a full `RemotePlaybackState` on connect, on every state
/// change, and a position tick each second while playing.
///
/// This is the read half of the Home Assistant handoff. HA (or the `/player` page, or anyone else)
/// commands the same engine this app does, and the engine fans every change out to all WS listeners
/// — so a pause from an HA dashboard flips this app's play button within a second, with no polling.
///
/// Reconnects with a fixed short backoff until the consuming task is cancelled. Messages that don't
/// decode are skipped, not fatal: the daemon may grow event types (captions are specced to join this
/// stream), and an unknown frame must not kill the subscription.
public struct DaemonEventsSocket: Sendable {
  private let endpoint: DaemonEndpoint
  private let session: URLSession
  private let authorization: AuthorizationProvider?
  private static let logger = Logger(label: "transcription.events")

  public init(
    endpoint: DaemonEndpoint = .current,
    session: URLSession = .shared,
    authorization: AuthorizationProvider? = nil
  ) {
    self.endpoint = endpoint
    self.session = session
    self.authorization = authorization
  }

  /// The daemon's `/events` URL with the scheme flipped to WebSocket.
  static func socketURL(for daemon: URL) -> URL? {
    guard var components = URLComponents(url: daemon, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/events"
    return components.url
  }

  /// Stream of playback states, ending only when the consuming task is cancelled.
  public func states() -> AsyncStream<RemotePlaybackState> {
    let endpoint = endpoint
    let session = session
    let authorization = authorization

    return AsyncStream { continuation in
      let task = Task {
        guard let url = Self.socketURL(for: endpoint.daemon) else {
          continuation.finish()
          return
        }
        while !Task.isCancelled {
          var request = URLRequest(url: url)
          if let bearer = await authorization?() {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
          }
          let socket = session.webSocketTask(with: request)
          socket.resume()

          do {
            while !Task.isCancelled {
              let message = try await socket.receive()
              guard case .string(let text) = message else { continue }
              if let state = try? JSONDecoder().decode(
                RemotePlaybackState.self,
                from: Data(text.utf8)
              ) {
                continuation.yield(state)
              }
            }
          } catch {
            Self.logger.debug("events socket dropped: \(error)")
          }
          socket.cancel(with: .goingAway, reason: nil)

          if !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
