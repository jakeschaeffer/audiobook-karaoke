import Foundation

/// One highlight of an audiobook: an in/out span, the transcript text it covered when it was made,
/// and an optional note. A digital sticky note on the book, nothing more.
///
/// Milliseconds are the truth. The excerpt is frozen text, never word indices or segment ids,
/// because `TranscriptStore.upsert` replaces whole chunks when a better tier lands
/// (docs/cross-repo-snips-plan.md, "The one mental model"). The record is also the export format:
/// `JSONDecoder` ignores unknown keys, so new fields are optional and need no migration; a
/// breaking change bumps `schema`.
public struct Snip: Codable, Identifiable, Hashable, Sendable {
  public static let currentSchema = "snip/1"

  public struct Source: Codable, Hashable, Sendable {
    public var kind: String
    public var title: String
    public var author: String?

    public init(kind: String = "abs-book", title: String, author: String?) {
      self.kind = kind
      self.title = title
      self.author = author
    }
  }

  /// Which output the tap was taken from: `local` (the phone), `speaker` (the WiiM), or
  /// `bookmark` when migrated from an Audiobookshelf bookmark.
  public enum Output: String, Codable, Sendable {
    case local
    case speaker
    case bookmark
  }

  public var schema: String
  public let id: String
  public let itemID: String
  public let serverID: String
  public var source: Source

  /// Player position at the tap, book-absolute.
  public let anchorMs: Int
  /// Start of the unbroken listening stretch containing the anchor (SnipCore.HeardTracker).
  public let heardFromMs: Int
  public let capturedAt: Date
  public let captureOutput: Output

  /// The highlight's In and Out points.
  public var startMs: Int
  public var endMs: Int
  /// The transcript text inside the span when it was last (re)read; nil when no text was stored
  /// for that stretch yet.
  public var excerpt: String?
  /// The best `TranscriptProvenance` tier the excerpt was read from, for "better text available"
  /// later. Raw value, so the record decodes without the Transcription module.
  public var excerptTier: String?
  /// The owner's own words. Never generated.
  public var note: String?

  public var updatedAt: Date
  /// Soft delete: the file stays on disk, the UI stops showing it.
  public var deletedAt: Date?
  /// The ABS bookmark (whole seconds) this snip was imported from, so the import runs once.
  public var importedBookmarkTime: Int?

  public init(
    id: String = UUID().uuidString,
    itemID: String,
    serverID: String,
    source: Source,
    anchorMs: Int,
    heardFromMs: Int,
    capturedAt: Date = Date(),
    captureOutput: Output,
    startMs: Int,
    endMs: Int,
    excerpt: String? = nil,
    excerptTier: String? = nil,
    note: String? = nil,
    importedBookmarkTime: Int? = nil
  ) {
    self.schema = Self.currentSchema
    self.id = id
    self.itemID = itemID
    self.serverID = serverID
    self.source = source
    self.anchorMs = anchorMs
    self.heardFromMs = heardFromMs
    self.capturedAt = capturedAt
    self.captureOutput = captureOutput
    self.startMs = startMs
    self.endMs = endMs
    self.excerpt = excerpt
    self.excerptTier = excerptTier
    self.note = note
    self.updatedAt = capturedAt
    self.deletedAt = nil
    self.importedBookmarkTime = importedBookmarkTime
  }

  public var lengthMs: Int { endMs - startMs }
  public var isDeleted: Bool { deletedAt != nil }

  enum CodingKeys: String, CodingKey {
    case schema, id
    case itemID = "item_id"
    case serverID = "server_id"
    case source
    case anchorMs = "anchor_ms"
    case heardFromMs = "heard_from_ms"
    case capturedAt = "captured_at"
    case captureOutput = "capture_output"
    case startMs = "start_ms"
    case endMs = "end_ms"
    case excerpt
    case excerptTier = "excerpt_tier"
    case note
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
    case importedBookmarkTime = "imported_bookmark_time"
  }
}

extension Snip {
  /// The JSON coding every snip file uses: ISO-8601 dates, stable key order for readable diffs.
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
