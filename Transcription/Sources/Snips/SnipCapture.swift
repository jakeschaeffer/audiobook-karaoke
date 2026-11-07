import Foundation
import Transcription

/// Turns a tap into a snip record. Pure: the caller supplies the sample, the heard-from point and
/// whatever transcript segments are stored around the tap.
public enum SnipCapture {
  public struct Context: Sendable {
    public let serverID: String
    public let source: Snip.Source
    public let sample: PlaybackSample
    public let heardFromMs: Int
    public let length: SnipLength

    public init(serverID: String, source: Snip.Source, sample: PlaybackSample, heardFromMs: Int, length: SnipLength) {
      self.serverID = serverID
      self.source = source
      self.sample = sample
      self.heardFromMs = heardFromMs
      self.length = length
    }
  }

  /// The span starts as `[max(heard_from, T − length), T]`: the chosen length, never reaching into
  /// audio that was skipped. Then `SentenceSnap` moves In to a nearby sentence start and Out to the
  /// end of the sentence being spoken. The excerpt is whatever text the store holds for it right now.
  public static func make(
    _ context: Context,
    segments: [TranscriptSegment],
    tiers: [Int: TranscriptProvenance] = [:]
  ) -> Snip {
    let anchor = context.sample.positionMs
    let floor = max(0, min(anchor, context.heardFromMs))
    let rawStart = max(floor, anchor - context.length.milliseconds)
    let snapped = SentenceSnap.snap(startMs: rawStart, endMs: anchor, floorMs: floor, segments: segments)
    let excerpt = TranscriptExcerpt.excerpt(
      from: segments,
      startMs: snapped.startMs,
      endMs: snapped.endMs,
      tiers: tiers
    )
    return Snip(
      itemID: context.sample.itemID,
      serverID: context.serverID,
      source: context.source,
      anchorMs: anchor,
      heardFromMs: context.heardFromMs,
      captureOutput: context.sample.output,
      startMs: snapped.startMs,
      endMs: snapped.endMs,
      excerpt: excerpt?.text,
      excerptTier: excerpt?.tier?.rawValue
    )
  }

  /// A snip standing in for an Audiobookshelf bookmark, which was a single whole-second point: a
  /// reviewed span when one exists (`CuratedBookmarkSpans`), otherwise the chosen length ending
  /// at the bookmark. The bookmark's title is kept as the note.
  public static func fromBookmark(
    time seconds: Int,
    title: String,
    createdAt: Date,
    itemID: String,
    serverID: String,
    source: Snip.Source,
    length: SnipLength,
    reviewedSpan: (startMs: Int, endMs: Int)? = nil,
    segments: [TranscriptSegment],
    tiers: [Int: TranscriptProvenance] = [:]
  ) -> Snip {
    let anchor = seconds * 1000
    let start = reviewedSpan?.startMs ?? max(0, anchor - length.milliseconds)
    let end = reviewedSpan?.endMs ?? anchor
    let excerpt = TranscriptExcerpt.excerpt(from: segments, startMs: start, endMs: end, tiers: tiers)
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return Snip(
      itemID: itemID,
      serverID: serverID,
      source: source,
      anchorMs: anchor,
      heardFromMs: start,
      capturedAt: createdAt,
      captureOutput: .bookmark,
      startMs: start,
      endMs: end,
      excerpt: excerpt?.text,
      excerptTier: excerpt?.tier?.rawValue,
      note: trimmed.isEmpty ? nil : trimmed,
      importedBookmarkTime: seconds
    )
  }
}
