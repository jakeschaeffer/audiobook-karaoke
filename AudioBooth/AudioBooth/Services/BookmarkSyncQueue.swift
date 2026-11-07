import API
import Foundation
import Logging
import Models
import SwiftData

final class BookmarkSyncQueue {
  static let shared = BookmarkSyncQueue()

  private var task: Task<Void, Never>?

  private init() {}

  func syncPending() {
    guard task == nil else {
      AppLogger.player.info("Bookmark sync already in progress")
      return
    }

    task = Task {
      defer { task = nil }

      do {
        var pendingBookmarks = try Bookmark.fetchAll()
        pendingBookmarks = pendingBookmarks.filter { [.pending, .failed].contains($0.status) }

        guard !pendingBookmarks.isEmpty else {
          AppLogger.player.info("No pending bookmarks to sync")
          return
        }

        AppLogger.player.info("Syncing \(pendingBookmarks.count) pending bookmark(s)")

        for bookmark in pendingBookmarks {
          await sync(bookmark)
        }

        AppLogger.player.info("Bookmark sync completed")
      } catch {
        AppLogger.player.error("Failed to fetch pending bookmarks: \(error)")
      }
    }
  }

  private func sync(_ bookmark: Bookmark) async {
    let bookID = bookmark.bookID
    let title = bookmark.title
    let time = bookmark.time

    do {
      let createdBookmark = try await Audiobookshelf.shared.bookmarks.create(
        bookID: bookID,
        title: title,
        time: time
      )

      bookmark.status = .synced
      bookmark.createdAt = Date(
        timeIntervalSince1970: TimeInterval(createdBookmark.createdAt / 1000)
      )
      try bookmark.save()

      AppLogger.player.info("Successfully synced bookmark: \(title)")
    } catch {
      bookmark.status = .failed
      try? bookmark.save()

      AppLogger.player.error("Failed to sync bookmark \(title): \(error)")
    }
  }

  func create(
    bookID: String,
    title: String,
    time: Int
  ) async throws -> Bookmark {
    let bookmark = Bookmark(
      bookID: bookID,
      time: time,
      title: title,
      createdAt: Date(),
      status: .pending
    )

    try bookmark.save()

    Task { @MainActor in
      await sync(bookmark)
    }

    return bookmark
  }

  func update(
    bookmark: Bookmark,
    newTitle: String
  ) async throws {
    let bookID = bookmark.bookID
    let time = bookmark.time
    let createdAt = bookmark.createdAt

    bookmark.title = newTitle
    bookmark.status = .pending
    try bookmark.save()

    Task { @MainActor in
      do {
        let apiBookmark = User.Bookmark(
          bookID: bookID,
          time: Double(time),
          title: newTitle,
          createdAt: Int64(createdAt.timeIntervalSince1970 * 1000)
        )

        _ = try await Audiobookshelf.shared.bookmarks.update(bookmark: apiBookmark)

        bookmark.status = .synced
        try bookmark.save()

        AppLogger.player.info("Successfully updated bookmark: \(newTitle)")
      } catch {
        bookmark.status = .failed
        try? bookmark.save()

        AppLogger.player.error("Failed to update bookmark: \(error)")
      }
    }
  }

  func delete(_ bookmark: Bookmark) async throws {
    let bookID = bookmark.bookID
    let time = bookmark.time
    let title = bookmark.title

    try bookmark.delete()

    Task { @MainActor in
      do {
        try await Audiobookshelf.shared.bookmarks.delete(bookID: bookID, time: time)
        AppLogger.player.info("Successfully deleted bookmark from server: \(title)")
      } catch {
        AppLogger.player.error("Failed to delete bookmark from server: \(error)")
      }
    }
  }
}
