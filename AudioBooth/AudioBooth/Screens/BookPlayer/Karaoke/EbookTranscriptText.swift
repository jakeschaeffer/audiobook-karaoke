import API
import Foundation
import Logging
import Models
import ReadiumShared
import ReadiumStreamer
import Transcription

/// Supplies an item's epub as plain text — the input `EbookAlignment` needs to make the book's
/// own prose the transcript.
///
/// App-side on purpose: epub access means Readium and the app's download/auth machinery, neither
/// of which belongs in the Transcription package. The package gets a `String`; everything Readium
/// stays here. Returns nil for "no epub / couldn't get it", which the session treats as "keep the
/// ASR transcript" — never an error the user has to see, because transcription itself succeeded.
enum EbookTranscriptText {
  private static let logger = Logger(label: "transcription.ebook")

  @MainActor
  static func text(forItem itemID: String) async -> String? {
    // A downloaded epub first (free: already on disk)…
    if let local = (try? LocalBook.fetch(bookID: itemID))?.ebookLocalPath {
      return await extract(from: local)
    }

    // …else pull it from ABS. A few MB — negligible next to the track audio the session just
    // downloaded, and worth it every time: this is what turns raw ASR into the printed book.
    guard let book = try? await Audiobookshelf.shared.books.fetch(id: itemID) else { return nil }
    let format = book.media.ebookFormat ?? book.media.ebookFile?.metadata.ext ?? ""
    guard format.lowercased().contains("epub") else {
      if book.media.ebookFile != nil {
        logger.info("item \(itemID) has a non-epub ebook (\(format)); alignment skipped")
      }
      return nil
    }
    guard let ebookURL = book.ebookURL else { return nil }

    var request = URLRequest(url: ebookURL)
    guard let server = Audiobookshelf.shared.authentication.server,
      let bearer = try? await server.freshToken.bearer
    else { return nil }
    request.setValue(bearer, forHTTPHeaderField: "Authorization")

    guard let (temporary, response) = try? await URLSession.shared.download(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else {
      logger.warning("epub download failed for \(itemID)")
      return nil
    }
    let epub = FileManager.default.temporaryDirectory
      .appending(path: "align-\(itemID).epub")
    try? FileManager.default.removeItem(at: epub)
    try? FileManager.default.moveItem(at: temporary, to: epub)
    defer { try? FileManager.default.removeItem(at: epub) }

    return await extract(from: epub)
  }

  /// Open with Readium (same opener stack as the ebook reader) and strip every reading-order
  /// document to prose. Detached: parsing plus stripping a whole book is real CPU work, and the
  /// caller sits on the main actor.
  private static func extract(from file: URL) async -> String? {
    await Task.detached(priority: .userInitiated) { () -> String? in
      guard let fileURL = FileURL(url: file) else { return nil }

      let httpClient = DefaultHTTPClient()
      let assetRetriever = AssetRetriever(httpClient: httpClient)
      let opener = PublicationOpener(
        parser: DefaultPublicationParser(
          httpClient: httpClient,
          assetRetriever: assetRetriever,
          pdfFactory: DefaultPDFDocumentFactory()
        )
      )

      guard let asset = try? await assetRetriever.retrieve(url: fileURL).get(),
        let publication = try? await opener.open(asset: asset, allowUserInteraction: false).get()
      else {
        logger.warning("Readium could not open epub at \(file.lastPathComponent)")
        return nil
      }

      var documents: [String] = []
      for link in publication.readingOrder {
        guard let resource = publication.get(link),
          let data = try? await resource.read().get(),
          let markup = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
        else { continue }
        documents.append(EbookHTML.plainText(fromXHTML: markup))
      }
      let text = EbookHTML.joinDocuments(documents)
      logger.info(
        "extracted \(documents.count) spine documents, \(text.count) characters"
      )
      return text.isEmpty ? nil : text
    }.value
  }
}
