import SwiftUI

extension View {
  func interactiveTarget() -> some View {
    #if targetEnvironment(macCatalyst)
    self
      .background(Color.black.opacity(0.001))
      .contentShape(Rectangle())
    #else
    self
      .contentShape(Rectangle())
    #endif
  }
}
