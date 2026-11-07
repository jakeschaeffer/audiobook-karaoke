import Foundation
import Logging
import SwiftData

/// One grid chunk, persisted.
///
/// The segments and their word timings live in `blob` as an opaque `Data` column rather than as a
/// `[TranscriptSegment]` Codable attribute. That's deliberate: SwiftData's handling of large codable
/// array attributes is the slow path, and here the ORM never sees the array at all — it sees one
/// column it doesn't interpret. Combined with chunk-granular rows it means ~243 rows and ~10KB blobs
/// for a 20h book, so an import is a loop rather than a bulk-insert problem.
@Model
public final class StoredChunk {
  /// `"<itemID>#<chunkIndex>"`. A compound uniqueness constraint would be the natural spelling, but
  /// `#Unique` is iOS 18+ and this package targets iOS 17 to match `Models`. Deriving a single unique
  /// key gets the same idempotency one deployment target lower.
  @Attribute(.unique) public var key: String
  public var itemID: String
  public var chunkIndex: Int
  public var minStart: TimeInterval
  public var maxEnd: TimeInterval
  public var provenanceRaw: String
  public var engineID: String
  public var segmentCount: Int
  public var blob: Data
  public var updatedAt: Date

  public var provenance: TranscriptProvenance {
    TranscriptProvenance(rawValue: provenanceRaw) ?? .hostRaw
  }

  static func key(itemID: String, chunkIndex: Int) -> String {
    "\(itemID)#\(chunkIndex)"
  }

  init(chunk: TranscriptChunk, blob: Data) {
    key = Self.key(itemID: chunk.itemID, chunkIndex: chunk.chunkIndex)
    itemID = chunk.itemID
    chunkIndex = chunk.chunkIndex
    minStart = chunk.minStart
    maxEnd = chunk.maxEnd
    provenanceRaw = chunk.provenance.rawValue
    engineID = chunk.engineID
    segmentCount = chunk.segments.count
    self.blob = blob
    updatedAt = Date()
  }
}

/// Schema owned by this package.
///
/// Deliberately *not* added to `AudiobookshelfSchema`. That schema is at version (0,0,3), is owned
/// upstream, and its container is built without a `MigrationPlan` inside a `do/catch` that deletes the
/// database on any failure — so adding models there would make a transcript schema change capable of
/// wiping the user's downloads, progress, and bookmarks. Keeping our own schema also keeps the
/// eventual upstream PR additive.
enum TranscriptSchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
  static var models: [any PersistentModel.Type] { [StoredChunk.self] }
}

/// Persists and queries grid chunks.
///
/// A `@ModelActor`, so writes run off the main thread. This is the freedom a separate container buys:
/// `ModelContextProvider` hands out only `container.mainContext`, so every write through it is
/// `@MainActor` and a large import would stall the UI.
@ModelActor
public actor TranscriptStore {
  private static let logger = Logger(label: "transcription.store")

  @MainActor private static var sharedStores: [String: TranscriptStore] = [:]

  /// The store for one ABS server, created once per process.
  ///
  /// Callers must come through here rather than building containers ad hoc: a container per call site
  /// (e.g. one per sheet presentation) stacks multiple live Core Data containers on the same SQLite
  /// file inside one process, which wastes memory and invites locking weirdness for no benefit.
  @MainActor
  /// `appGroup` is the security application group whose container holds the database, injected
  /// because the group id is the app's identity, not the package's — this package used to
  /// hardcode the upstream group and silently fall back to Application Support on any other team.
  /// Nil means Application Support directly (no shared container).
  public static func shared(for serverID: String, appGroup: String?) throws -> TranscriptStore {
    if let existing = sharedStores[serverID] {
      return existing
    }
    let store = TranscriptStore(
      modelContainer: try container(serverID: serverID, appGroup: appGroup)
    )
    sharedStores[serverID] = store

    // Installs that predate the app group (or ran while its container couldn't resolve) kept
    // their transcripts at the Application Support fallback. Adopt them into the shared
    // container — otherwise every chunk the device transcribed, aligned, or cleaned looks
    // vanished the day the store moves, and re-imports arrive at whatever (possibly lower)
    // tier the server holds. This bit for real: a device's LLM-cleaned book "reverted" to raw.
    let legacy = databaseURL(serverID: serverID, appGroup: nil)
    if appGroup != nil,
      legacy != databaseURL(serverID: serverID, appGroup: appGroup),
      FileManager.default.fileExists(atPath: legacy.path),
      // Created here on the main actor like every other container this type makes: concurrent
      // first-time container creation races SwiftData's schema registration (see TestContainers).
      let legacyContainer = try? ModelContainer(
        for: Schema(versionedSchema: TranscriptSchemaV1.self),
        configurations: ModelConfiguration(url: legacy, allowsSave: false)
      )
    {
      Task { await store.adoptLegacyStore(legacyContainer, at: legacy) }
    }
    return store
  }

  /// Build a container for one ABS server.
  ///
  /// Mirrors upstream's per-server App Group layout (`group.me.jgrenier.audioBS/<serverID>/`) because
  /// that layout is *right* — transcripts are keyed by ABS `item_id`, which is only unique within a
  /// server, and sharing the App Group container keeps a future watch/widget karaoke surface possible.
  /// It mirrors the layout without touching the file that defines it.
  ///
  /// On failure this does **not** delete and recreate. Upstream's destructive fallback is defensible
  /// for a re-downloadable cache; it is not defensible here, because on-device chunks cost battery and
  /// thermal budget and cannot be cheaply re-derived. Quarantine and surface instead. This is a
  /// deliberate divergence from the codebase's idiom and worth calling out in review.
  public static func container(serverID: String, appGroup: String?) throws -> ModelContainer {
    let url = databaseURL(serverID: serverID, appGroup: appGroup)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let schema = Schema(versionedSchema: TranscriptSchemaV1.self)
    let configuration = ModelConfiguration(url: url, allowsSave: true)
    do {
      return try ModelContainer(for: schema, configurations: configuration)
    } catch {
      logger.error(
        "Transcript store failed to open; quarantining rather than deleting: \(error)"
      )
      // Move the whole SQLite file *family*. Quarantining only the main file would leave a stale
      // -wal/-shm pair behind at the original path, and a fresh database created there next launch
      // would sit beside journal files that don't belong to it.
      let stamp = Int(Date().timeIntervalSince1970)
      for suffix in ["", "-shm", "-wal"] {
        let member = URL(fileURLWithPath: url.path + suffix)
        let quarantine = URL(fileURLWithPath: url.path + suffix + ".quarantined-\(stamp)")
        try? FileManager.default.moveItem(at: member, to: quarantine)
      }
      throw error
    }
  }

  static func databaseURL(serverID: String, appGroup: String?) -> URL {
    let root =
      appGroup.flatMap {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
      }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return root.appending(path: serverID).appending(path: "Transcripts.sqlite")
  }

  // MARK: - Writes

  /// Commit one completed chunk. Idempotent on `(itemID, chunkIndex)`.
  ///
  /// Conflict rule: higher `provenance.quality` wins, ties go to the newer write. That's what lets a
  /// host import supersede on-device chunks, and stage-2 cleaned prose supersede raw ASR, without any
  /// caller coordinating. Re-import, re-transcribe, or retry after a crash are all no-ops.
  public func commit(_ chunk: TranscriptChunk) throws {
    try upsert(chunk)
    try modelContext.save()
  }

  /// Commit many chunks in one transaction.
  ///
  /// Not a distinct import path — the same upsert with the save hoisted out, purely to batch the
  /// ~243 writes of a whole-book import. If this needed different logic, the producer seam would be
  /// wrong.
  public func commit(contentsOf chunks: [TranscriptChunk]) throws {
    for chunk in chunks {
      try upsert(chunk)
    }
    try modelContext.save()
  }

  private func upsert(_ chunk: TranscriptChunk) throws {
    let key = StoredChunk.key(itemID: chunk.itemID, chunkIndex: chunk.chunkIndex)
    var descriptor = FetchDescriptor<StoredChunk>(predicate: #Predicate { $0.key == key })
    descriptor.fetchLimit = 1

    if let existing = try modelContext.fetch(descriptor).first {
      guard chunk.provenance.quality >= existing.provenance.quality else { return }
      existing.blob = try ChunkCodec.encode(chunk.segments)
      existing.minStart = chunk.minStart
      existing.maxEnd = chunk.maxEnd
      existing.provenanceRaw = chunk.provenance.rawValue
      existing.engineID = chunk.engineID
      existing.segmentCount = chunk.segments.count
      existing.updatedAt = Date()
    } else {
      modelContext.insert(StoredChunk(chunk: chunk, blob: try ChunkCodec.encode(chunk.segments)))
    }
  }

  // MARK: - Reads

  /// Local coverage for an item, derived from the rows rather than stored alongside them.
  ///
  /// Deriving keeps coverage from ever drifting out of sync with reality: a row exists if and only if
  /// that chunk is complete.
  public func coverage(forItem itemID: String) throws -> TranscriptCoverage {
    let descriptor = FetchDescriptor<StoredChunk>(predicate: #Predicate { $0.itemID == itemID })
    let rows = try modelContext.fetch(descriptor)
    return TranscriptCoverage(chunks: Set(rows.map(\.chunkIndex)))
  }

  /// Segments overlapping `range`, in ascending order.
  ///
  /// The only read the views are allowed. Turns the float window into integer chunk lookups, decodes
  /// the touched blobs, then trims on overlap. If a view needs something past this API, the model is
  /// wrong.
  public func segments(
    forItem itemID: String,
    in range: ClosedRange<TimeInterval>
  ) throws -> [TranscriptSegment] {
    let indices = Array(TranscriptGrid.indices(covering: range))
    let descriptor = FetchDescriptor<StoredChunk>(
      predicate: #Predicate { $0.itemID == itemID && indices.contains($0.chunkIndex) },
      sortBy: [SortDescriptor(\.chunkIndex)]
    )
    let rows = try modelContext.fetch(descriptor)
    return
      try rows
      .flatMap { try ChunkCodec.decode($0.blob) }
      .filter { $0.end > range.lowerBound && $0.start < range.upperBound }
      .sorted { $0.start < $1.start }
  }

  /// Total stored segments for an item — cheap, from row metadata, without decoding blobs.
  public func segmentCount(forItem itemID: String) throws -> Int {
    let descriptor = FetchDescriptor<StoredChunk>(predicate: #Predicate { $0.itemID == itemID })
    return try modelContext.fetch(descriptor).reduce(0) { $0 + $1.segmentCount }
  }

  /// Chunk counts by provenance — row metadata only, no blob decodes. How a caller decides
  /// whether alignment still has anything to improve (all-`ebookAligned` means it doesn't).
  public func provenanceCounts(forItem itemID: String) throws -> [TranscriptProvenance: Int] {
    let descriptor = FetchDescriptor<StoredChunk>(predicate: #Predicate { $0.itemID == itemID })
    var counts: [TranscriptProvenance: Int] = [:]
    for row in try modelContext.fetch(descriptor) {
      counts[row.provenance, default: 0] += 1
    }
    return counts
  }

  /// Provenance per stored chunk — row metadata only, no blob decodes. The cleanup pass's work
  /// queue: chunks whose tier is below `.onDeviceLLMCleaned` still have something to gain.
  public func chunkProvenances(forItem itemID: String) throws -> [Int: TranscriptProvenance] {
    let descriptor = FetchDescriptor<StoredChunk>(predicate: #Predicate { $0.itemID == itemID })
    var tiers: [Int: TranscriptProvenance] = [:]
    for row in try modelContext.fetch(descriptor) {
      tiers[row.chunkIndex] = row.provenance
    }
    return tiers
  }

  /// Drop an item's transcript. Only ever user-initiated — nothing here evicts automatically.
  public func delete(itemID: String) throws {
    try modelContext.delete(model: StoredChunk.self, where: #Predicate { $0.itemID == itemID })
    try modelContext.save()
  }

  // MARK: - Legacy-path adoption

  /// One-time adoption of a store left behind at the pre-app-group path.
  ///
  /// Every chunk flows through the same higher-quality-wins upsert as a live commit, so adopting
  /// into a store that already re-accumulated fresh (possibly lower-tier) imports is safe in both
  /// directions — the best tier per chunk survives no matter which side holds it. The legacy file
  /// family is renamed on success, which is what makes this once; on failure it's left untouched
  /// for the next launch to retry. Never destructive.
  func adoptLegacyStore(_ legacy: ModelContainer, at legacyURL: URL) {
    do {
      let context = ModelContext(legacy)
      let rows = try context.fetch(FetchDescriptor<StoredChunk>())
      for row in rows {
        try upsert(
          TranscriptChunk(
            itemID: row.itemID,
            chunkIndex: row.chunkIndex,
            segments: try ChunkCodec.decode(row.blob),
            provenance: row.provenance,
            engineID: row.engineID
          )
        )
      }
      try modelContext.save()
      for suffix in ["", "-shm", "-wal"] {
        let member = URL(fileURLWithPath: legacyURL.path + suffix)
        let retired = URL(fileURLWithPath: legacyURL.path + suffix + ".migrated")
        try? FileManager.default.moveItem(at: member, to: retired)
      }
      Self.logger.info("adopted \(rows.count) chunks from the pre-app-group store")
    } catch {
      Self.logger.error("legacy store adoption failed (left in place): \(error)")
    }
  }
}

/// Encodes a chunk's segments into its opaque blob column.
///
/// Compact JSON plus zlib. The host's raw JSONL is only ~2MB per 20h book, so ~8KB per chunk before
/// compression — there is no need for a bespoke binary format, and JSON keeps the stored bytes
/// debuggable. Revisit only if profiling says so.
enum ChunkCodec {
  static func encode(_ segments: [TranscriptSegment]) throws -> Data {
    let json = try JSONEncoder().encode(segments)
    return try (json as NSData).compressed(using: .zlib) as Data
  }

  static func decode(_ blob: Data) throws -> [TranscriptSegment] {
    let json = try (blob as NSData).decompressed(using: .zlib) as Data
    return try JSONDecoder().decode([TranscriptSegment].self, from: json)
  }
}
