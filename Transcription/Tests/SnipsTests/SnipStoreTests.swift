import Foundation
import Testing

@testable import Snips

struct SnipStoreTests {
  private func makeStore() -> SnipStore {
    let root = FileManager.default.temporaryDirectory.appending(path: "SnipStoreTests-\(UUID().uuidString)")
    return SnipStore(root: root)
  }

  private func sample(_ note: String? = nil) -> Snip {
    Snip(
      itemID: "book-1",
      serverID: "server-a",
      source: .init(title: "A Book", author: "Someone"),
      anchorMs: 90_000,
      heardFromMs: 20_000,
      captureOutput: .local,
      startMs: 30_000,
      endMs: 90_000,
      excerpt: "some words",
      note: note
    )
  }

  @Test func roundTripsThroughFilesAndAFreshIndex() async throws {
    let store = makeStore()
    let snip = sample("remember this")
    try await store.save(snip)

    let again = SnipStore(root: await store.root)
    let loaded = try await again.snips(forItem: "book-1", serverID: "server-a")
    #expect(loaded.count == 1)
    #expect(loaded[0].id == snip.id)
    #expect(loaded[0].note == "remember this")
    #expect(loaded[0].excerpt == "some words")
    #expect(loaded[0].startMs == 30_000)
    #expect(loaded[0].schema == Snip.currentSchema)
  }

  @Test func softDeleteHidesButKeepsTheFile() async throws {
    let store = makeStore()
    let snip = sample()
    try await store.save(snip)
    try await store.delete(id: snip.id)
    #expect(try await store.snips(forItem: "book-1", serverID: "server-a").isEmpty)
    let url = await store.root.appending(path: "server-a/book-1/\(snip.id).json")
    #expect(FileManager.default.fileExists(atPath: url.path))
    try await store.restore(id: snip.id)
    #expect(try await store.snips(forItem: "book-1", serverID: "server-a").count == 1)
  }

  @Test func unreadableFilesAreCountedNotDeleted() async throws {
    let store = makeStore()
    try await store.save(sample())
    let bad = await store.root.appending(path: "server-a/book-1/broken.json")
    try Data("{not json".utf8).write(to: bad)

    let again = SnipStore(root: await store.root)
    #expect(try await again.snips(forItem: "book-1", serverID: "server-a").count == 1)
    #expect(try await again.unreadableCount() == 1)
    #expect(FileManager.default.fileExists(atPath: bad.path))
  }

  @Test func unknownKeysAreIgnoredOnDecode() throws {
    var json = try JSONSerialization.jsonObject(with: Snip.encoder().encode(sample())) as! [String: Any]
    json["future_field"] = ["x": 1]
    let data = try JSONSerialization.data(withJSONObject: json)
    let decoded = try Snip.decoder().decode(Snip.self, from: data)
    #expect(decoded.itemID == "book-1")
  }
}
