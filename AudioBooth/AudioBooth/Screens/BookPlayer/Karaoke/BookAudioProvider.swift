import Foundation
import Models
import Transcription

/// Audio for the transcription engine from the book's own downloaded files — the provider any
/// Audiobookshelf install can have, no server required. `Models.Track` maps field-for-field onto
/// `TrackInfo`, and `Track.localPath` is the file `AVAudioFile` reads; `isTemporary: false` is
/// load-bearing — these are the user's downloads, and the session must not delete them.
struct BookAudioProvider: TranscriptionAudioProvider {
  func tracks(forItem itemID: String) async throws -> [TrackInfo] {
    guard let book = try await fetchBook(itemID) else {
      throw TranscriptionError.audioNotDownloaded
    }
    return book.map { TrackInfo(index: $0.index, start: $0.startOffset, duration: $0.duration) }
  }

  func audio(forItem itemID: String, track: TrackInfo) async throws -> TranscriptionAudio {
    guard let book = try await fetchBook(itemID),
      let match = book.first(where: { $0.index == track.index }),
      let url = match.localPath
    else {
      throw TranscriptionError.audioNotDownloaded
    }
    return TranscriptionAudio(url: url, isTemporary: false)
  }

  /// Ordered tracks of a fully-downloaded book, or nil. Partial downloads count as not
  /// downloaded: transcribing half a book from local files and silently skipping the rest would
  /// read as a bug, not a feature.
  @MainActor
  private func fetchBook(_ itemID: String) throws -> [Track]? {
    guard let book = try LocalBook.fetch(bookID: itemID) else { return nil }
    let tracks = book.orderedTracks
    guard !tracks.isEmpty, tracks.allSatisfy({ $0.localPath != nil }) else { return nil }
    return tracks
  }
}

/// The fork's composition: local files when the book is downloaded (no network, no server load),
/// the daemon's authenticated `/audio` proxy otherwise. Upstream installs would use
/// `BookAudioProvider` alone.
struct CompositeAudioProvider: TranscriptionAudioProvider {
  let local: BookAudioProvider
  let daemon: HostTranscriptSource

  func tracks(forItem itemID: String) async throws -> [TrackInfo] {
    do {
      return try await local.tracks(forItem: itemID)
    } catch TranscriptionError.audioNotDownloaded {
      return try await daemon.tracks(forItem: itemID)
    }
  }

  func audio(forItem itemID: String, track: TrackInfo) async throws -> TranscriptionAudio {
    do {
      return try await local.audio(forItem: itemID, track: track)
    } catch TranscriptionError.audioNotDownloaded {
      return try await daemon.audio(forItem: itemID, track: track)
    }
  }
}
