import SwiftUI

struct Chip: View {
  enum Mode {
    case small
    case large
  }

  let title: String
  let icon: String?
  let color: Color
  let mode: Mode

  init(title: String, icon: String? = nil, color: Color, mode: Mode = .small) {
    self.title = title
    self.icon = icon
    self.color = color
    self.mode = mode
  }

  var body: some View {
    HStack(spacing: spacing) {
      if let icon {
        Image(systemName: icon)
          .accessibilityHidden(true)
          .font(iconFont)
      }

      Text(title)
        .font(textFont)
        .fontWeight(.medium)
    }
    .foregroundColor(color)
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .background(color.opacity(0.1))
    .clipShape(.capsule)
    .overlay(
      Capsule()
        .stroke(color.opacity(0.3), lineWidth: 1)
    )
  }

  private var spacing: CGFloat {
    switch mode {
    case .small: 4
    case .large: 6
    }
  }

  private var iconFont: Font {
    switch mode {
    case .small: .caption2
    case .large: .caption
    }
  }

  private var textFont: Font {
    switch mode {
    case .small: .caption
    case .large: .subheadline
    }
  }

  private var horizontalPadding: CGFloat {
    switch mode {
    case .small: 10
    case .large: 12
    }
  }

  private var verticalPadding: CGFloat {
    switch mode {
    case .small: icon != nil ? 6 : 4
    case .large: icon != nil ? 8 : 6
    }
  }
}
