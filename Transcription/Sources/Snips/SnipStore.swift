import Foundation
import Logging

/// One JSON file per snip under `<root>/<serverID>/<itemID>/<snipID>.json`, written atomically. An
/// in-memory index is built on first use.
///
/// Files rather than SwiftData, deliberately: the app's schema deletes the whole database when it
/// fails to open, and a snip you wrote must never vanish that way. A file that fails to decode
/// stays where it is, is logged, and is counted in `unreadableCount` so the UI can say so.
public actor SnipStore {
  private static let logger = Logger(label: "snips.store")

  public let root: URL
  private var index: [String: Snip] = [:]
  private var unreadable: [URL] = []
  private var loaded = false

  /// The default location: Application Support/Snips, which iOS backs up.
  public static func defaultRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appending(path: "Snips")
  }

  public init(root: URL) {
    self.root = root
  }

  // MARK: - Reads

  /// Live snips for one book, newest first.
  public func snips(forItem itemID: String, serverID: String) throws -> [Snip] {
    try loadIfNeeded()
    return index.values
      .filter { $0.itemID == itemID && $0.serverID == serverID && !$0.isDeleted }
      .sorted { $0.capturedAt > $1.capturedAt }
  }

  /// Every live snip, newest first.
  public func all() throws -> [Snip] {
    try loadIfNeeded()
    return index.values.filter { !$0.isDeleted }.sorted { $0.capturedAt > $1.capturedAt }
  }

  public func snip(id: String) throws -> Snip? {
    try loadIfNeeded()
    return index[id]
  }

  /// Files on disk that did not decode. Never deleted by the store.
  public func unreadableCount() throws -> Int {
    try loadIfNeeded()
    return unreadable.count
  }

  // MARK: - Writes

  public func save(_ snip: Snip) throws {
    try loadIfNeeded()
    var record = snip
    record.updatedAt = Date()
    let url = fileURL(for: record)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Snip.encoder().encode(record).write(to: url, options: .atomic)
    index[record.id] = record
  }

  /// Soft delete: the record is kept with `deleted_at` set.
  public func delete(id: String) throws {
    try loadIfNeeded()
    guard var record = index[id] else { return }
    record.deletedAt = Date()
    try save(record)
  }

  /// Undo a soft delete (the capture card's Undo, a list swipe taken back).
  public func restore(id: String) throws {
    try loadIfNeeded()
    guard var record = index[id] else { return }
    record.deletedAt = nil
    try save(record)
  }

  // MARK: - Files

  private func fileURL(for snip: Snip) -> URL {
    root.appending(path: snip.serverID).appending(path: snip.itemID).appending(path: "\(snip.id).json")
  }

  private func loadIfNeeded() throws {
    guard !loaded else { return }
    loaded = true
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { return }
    guard
      let files = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return }
    let decoder = Snip.decoder()
    for case let url as URL in files where url.pathExtension == "json" {
      do {
        let snip = try decoder.decode(Snip.self, from: Data(contentsOf: url))
        index[snip.id] = snip
      } catch {
        Self.logger.error("Snip file could not be read, left in place: \(url.lastPathComponent): \(error)")
        unreadable.append(url)
      }
    }
  }
}
