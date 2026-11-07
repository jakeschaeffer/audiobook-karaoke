import SwiftUI

extension View {
  @ViewBuilder
  func displayScaled() -> some View {
    #if targetEnvironment(macCatalyst)
    modifier(DisplayScaleModifier())
    #else
    self
    #endif
  }

  @ViewBuilder
  func displaySheetScaled(baseWidth: CGFloat = 540, baseHeight: CGFloat = 700) -> some View {
    #if targetEnvironment(macCatalyst)
    modifier(DisplaySheetScaleModifier(baseWidth: baseWidth, baseHeight: baseHeight))
    #else
    self
    #endif
  }
}

#if targetEnvironment(macCatalyst)
struct DisplaySheetScaleModifier: ViewModifier {
  @ObservedObject private var preferences = UserPreferences.shared
  let baseWidth: CGFloat
  let baseHeight: CGFloat

  func body(content: Content) -> some View {
    let scale = preferences.displayScale
    let maxHeight = UIScreen.main.bounds.height * 0.9
    content
      .modifier(DisplayScaleModifier())
      .frame(
        width: baseWidth * scale,
        height: min(baseHeight * scale, maxHeight)
      )
  }
}

struct DisplayScaleModifier: ViewModifier {
  @ObservedObject private var preferences = UserPreferences.shared

  func body(content: Content) -> some View {
    let scale = preferences.displayScale
    GeometryReader { geometry in
      content
        .frame(
          width: geometry.size.width / scale,
          height: geometry.size.height / scale
        )
        .scaleEffect(scale)
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }
}
#endif
