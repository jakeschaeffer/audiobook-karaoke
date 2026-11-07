import Foundation

@MainActor
public protocol PlayableItem {
  var title: String { get }
  var details: String { get }
  var duration: TimeInterval { get }
  var orderedTracks: [Track] { get }
  var orderedChapters: [Chapter] { get }
  var isDownloaded: Bool { get }
}
