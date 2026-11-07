import Foundation
import SwiftData

@testable import Transcription

/// Serialized `ModelContainer` creation for tests.
///
/// swift-testing runs suites in parallel, and concurrent creation of containers over the same
/// `@Model` types races SwiftData's one-time schema registration — the whole test process dies with
/// SIGSEGV, intermittently (observed roughly every other full run; 3/3 stable with `--no-parallel`).
/// Locking creation is sufficient: usage after creation is confined to each test's own container.
enum TestContainers {
  private static let lock = NSLock()

  static func makeInMemory() throws -> ModelContainer {
    lock.lock()
    defer { lock.unlock() }
    let schema = Schema(versionedSchema: TranscriptSchemaV1.self)
    return try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  static func makeOnDisk(at url: URL) throws -> ModelContainer {
    lock.lock()
    defer { lock.unlock() }
    let schema = Schema(versionedSchema: TranscriptSchemaV1.self)
    return try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(url: url, allowsSave: true)
    )
  }
}
