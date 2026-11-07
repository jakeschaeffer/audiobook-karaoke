import Foundation

/// One reading of "what is playing right now", taken by the app layer. The package never asks the
/// players itself: the app knows about the speaker and the compile-time flags, the package doesn't.
public struct PlaybackSample: Sendable, Equatable {
  public let itemID: String
  /// Book-absolute seconds.
  public let position: TimeInterval
  public let isPlaying: Bool
  public let speed: Double
  public let output: Snip.Output

  public init(itemID: String, position: TimeInterval, isPlaying: Bool, speed: Double, output: Snip.Output) {
    self.itemID = itemID
    self.position = position
    self.isPlaying = isPlaying
    self.speed = speed
    self.output = output
  }

  public var positionMs: Int { Int((position * 1000).rounded()) }
}
