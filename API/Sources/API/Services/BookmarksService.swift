import Foundation

public final class BookmarksService {
  private let audiobookshelf: Audiobookshelf

  init(audiobookshelf: Audiobookshelf) {
    self.audiobookshelf = audiobookshelf
  }

  public func create(bookID: String, title: String, time: Int) async throws -> User.Bookmark {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    struct CreateRequest: Codable {
      let title: String
      let time: Int
    }

    let requestBody = CreateRequest(title: title, time: time)
    let request = NetworkRequest<User.Bookmark>(
      path: "/api/me/item/\(bookID)/bookmark",
      method: .post,
      body: requestBody
    )

    let response = try await networkService.send(request)
    return response.value
  }

  public func delete(bookID: String, time: Int) async throws {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    let request = NetworkRequest<Data>(
      path: "/api/me/item/\(bookID)/bookmark/\(time)",
      method: .delete
    )

    _ = try await networkService.send(request)
  }

  public func update(bookmark: User.Bookmark) async throws -> User.Bookmark {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    let request = NetworkRequest<User.Bookmark>(
      path: "/api/me/item/\(bookmark.bookID)/bookmark",
      method: .patch,
      body: bookmark
    )

    let response = try await networkService.send(request)
    return response.value
  }
}
