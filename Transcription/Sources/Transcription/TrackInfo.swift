import Foundation

/// One audio track's place in the book. `index` is 1-based (there is no track 0 anywhere in this
/// pipeline) and `start` is the book-absolute offset that turns in-track transcription times into
/// book positions.
///
/// A top-level type on purpose: it used to be nested in the daemon client, which quietly made the
/// whole transcription engine daemon-shaped. Every audio source describes tracks this way —
/// `Models.Track` (index/startOffset/duration) maps field-for-field — so the type belongs to the
/// engine, and wire formats map into it privately at their own edges.
public struct TrackInfo: Equatable, Sendable {
  public let index: Int
  public let start: TimeInterval
  public let duration: TimeInterval

  public init(index: Int, start: TimeInterval, duration: TimeInterval) {
    self.index = index
    self.start = start
    self.duration = duration
  }
}
