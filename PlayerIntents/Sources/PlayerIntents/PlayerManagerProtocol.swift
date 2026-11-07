import Foundation

public protocol PlayerManagerProtocol: Sendable {
  func play()
  func pause()
  func play(_ bookID: String) async
  func open(_ bookID: String) async
}
