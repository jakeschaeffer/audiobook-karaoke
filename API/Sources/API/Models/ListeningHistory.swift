import Foundation

public struct ListeningHistoryResponse: Codable {
  public let total: Int
  public let numPages: Int
  public let page: Int
  public let itemsPerPage: Int
  public let sessions: [ListeningHistorySession]
}

public struct ListeningHistorySession: Codable, Identifiable {
  public let id: String
  public let libraryItemId: String
  public let displayTitle: String?
  public let displayAuthor: String?
  public let coverPath: String?
  public let timeListening: Double?
  public let updatedAt: Double
}
