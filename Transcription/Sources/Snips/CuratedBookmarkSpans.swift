import Foundation

/// Reviewed In/Out points for Audiobookshelf bookmarks, keyed by book and bookmark second. A
/// bookmark was tapped at the Out point; where the idea began was read from the transcript and
/// reviewed by hand (the app ships `bookmark-spans.json`). Bookmarks not listed import with the
/// chosen snip length instead.
public struct CuratedBookmarkSpans: Decodable, Sendable {
  public struct Entry: Decodable, Sendable, Equatable {
    public let itemID: String
    public let bookmarkTime: Int
    public let startMs: Int
    public let endMs: Int

    enum CodingKeys: String, CodingKey {
      case itemID = "item_id"
      case bookmarkTime = "bookmark_time"
      case startMs = "start_ms"
      case endMs = "end_ms"
    }
  }

  public let schema: String
  public let spans: [Entry]

  public static let empty = CuratedBookmarkSpans(schema: "bookmark-spans/1", spans: [])

  public init(schema: String, spans: [Entry]) {
    self.schema = schema
    self.spans = spans
  }

  public init(data: Data) throws {
    self = try JSONDecoder().decode(CuratedBookmarkSpans.self, from: data)
  }

  /// The reviewed span for a bookmark, or nil when none was recorded. Only sane entries count:
  /// In before Out, Out at or after the bookmark.
  public func span(itemID: String, bookmarkTime: Int) -> (startMs: Int, endMs: Int)? {
    guard
      let entry = spans.first(where: { $0.itemID == itemID && $0.bookmarkTime == bookmarkTime }),
      entry.startMs < entry.endMs, entry.endMs >= bookmarkTime * 1000
    else { return nil }
    return (entry.startMs, entry.endMs)
  }
}
