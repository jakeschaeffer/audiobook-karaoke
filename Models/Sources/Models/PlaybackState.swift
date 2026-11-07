import Foundation

public struct PlaybackState: Codable, Sendable {
  public let bookID: String
  public let title: String
  public let author: String
  public let coverURL: URL?
  public let currentTime: Double
  public let duration: Double
  public let isPlaying: Bool
  public let playbackSpeed: Float

  public init(
    bookID: String,
    title: String,
    author: String,
    coverURL: URL?,
    currentTime: Double,
    duration: Double,
    isPlaying: Bool,
    playbackSpeed: Float = 1.0
  ) {
    self.bookID = bookID
    self.title = title
    self.author = author
    self.coverURL = coverURL
    self.currentTime = currentTime
    self.duration = duration
    self.isPlaying = isPlaying
    self.playbackSpeed = playbackSpeed
  }

  public var progress: Double {
    guard duration > 0 else { return 0 }
    return currentTime / duration
  }
}
