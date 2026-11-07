import Foundation

enum CollectionMode: Identifiable {
  case playlists
  case collections

  var id: Self { self }
}
