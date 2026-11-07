import Foundation

public final class MiscService {
  private let audiobookshelf: Audiobookshelf

  init(audiobookshelf: Audiobookshelf) {
    self.audiobookshelf = audiobookshelf
  }

  public func sendEbookToDevice(
    itemID: String,
    deviceName: String
  ) async throws {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    struct EbookRequest: Codable {
      let libraryItemId: String
      let deviceName: String
    }

    let requestBody = EbookRequest(libraryItemId: itemID, deviceName: deviceName)

    let request = NetworkRequest<Data>(
      path: "/api/emails/send-ebook-to-device",
      method: .post,
      body: requestBody
    )

    _ = try await networkService.send(request)
  }
}
