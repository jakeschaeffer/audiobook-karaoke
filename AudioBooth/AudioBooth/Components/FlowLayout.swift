import SwiftUI

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = computeRows(proposal: proposal, subviews: subviews)
    return CGSize(
      width: proposal.width ?? 0,
      height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let rows = computeRows(proposal: proposal, subviews: subviews)
    var y = bounds.minY

    for row in rows {
      var x = bounds.minX
      for subview in row.subviews {
        let size = subview.sizeThatFits(.unspecified)
        subview.place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
          proposal: .unspecified
        )
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var currentRow: [LayoutSubview] = []
    var currentRowWidth: CGFloat = 0
    var currentRowHeight: CGFloat = 0

    let maxWidth = proposal.width ?? .infinity

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let needsNewRow = currentRowWidth + size.width + (currentRow.isEmpty ? 0 : spacing) > maxWidth

      if needsNewRow && !currentRow.isEmpty {
        rows.append(Row(subviews: currentRow, height: currentRowHeight))
        currentRow = []
        currentRowWidth = 0
        currentRowHeight = 0
      }

      currentRow.append(subview)
      currentRowWidth += size.width + (currentRow.count > 1 ? spacing : 0)
      currentRowHeight = max(currentRowHeight, size.height)
    }

    if !currentRow.isEmpty {
      rows.append(Row(subviews: currentRow, height: currentRowHeight))
    }

    return rows
  }

  private struct Row {
    let subviews: [LayoutSubview]
    let height: CGFloat
  }
}
