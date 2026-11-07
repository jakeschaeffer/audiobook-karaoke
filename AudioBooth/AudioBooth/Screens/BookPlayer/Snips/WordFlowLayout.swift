import SwiftUI

/// Lays words out left to right, wrapping like text, so each word can be its own tappable view.
struct WordFlowLayout: Layout {
  var spacing: CGFloat = 5
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    return place(in: width, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let layout = place(in: bounds.width, subviews: subviews)
    for (index, origin) in layout.origins.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: .unspecified
      )
    }
  }

  private func place(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var maxX: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      maxX = max(maxX, x - spacing)
    }
    return (CGSize(width: maxX, height: y + lineHeight), origins)
  }
}
