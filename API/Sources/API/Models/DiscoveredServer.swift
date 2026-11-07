import Foundation

public struct DiscoveredServer: Identifiable, Sendable {
  public let id = UUID()
  public let serverURL: URL
  public let responseTime: TimeInterval
  public let serverInfo: ServerInfo?

  public init(serverURL: URL, responseTime: TimeInterval, serverInfo: ServerInfo? = nil) {
    self.serverURL = serverURL
    self.responseTime = responseTime
    self.serverInfo = serverInfo
  }

  public struct ServerInfo: Codable, Sendable {
    public let version: String?
    public let name: String?

    public init(version: String? = nil, name: String? = nil) {
      self.version = version
      self.name = name
    }
  }
}
