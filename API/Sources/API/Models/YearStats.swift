import Foundation

public struct YearStats: Codable {
  public let totalListeningSessions: Int
  public let totalListeningTime: Double
  public let totalBookListeningTime: Double
  public let totalPodcastListeningTime: Double
  public let topAuthors: [TopAuthor]
  public let topGenres: [TopGenre]
  public let mostListenedNarrator: MostListenedNarrator?
  public let mostListenedMonth: MostListenedMonth?
  public let numBooksFinished: Int
  public let numBooksListened: Int
  public let longestAudiobookFinished: LongestAudiobook?
  public let booksWithCovers: [String]
  public let finishedBooksWithCovers: [String]

  public struct TopAuthor: Codable {
    public let name: String
    public let time: Double
  }

  public struct TopGenre: Codable {
    public let genre: String
    public let time: Double
  }

  public struct MostListenedNarrator: Codable {
    public let name: String
    public let time: Double
  }

  public struct MostListenedMonth: Codable {
    public let month: Int
    public let time: Double
  }

  public struct LongestAudiobook: Codable {
    public let id: String
    public let title: String
    public let duration: Double
    public let finishedAt: String
  }
}
