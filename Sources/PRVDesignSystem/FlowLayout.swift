import SwiftUI

/// A left-aligned flow layout for chip grids: subviews are laid out in
/// horizontal rows and wrap to a new row when the available width is
/// exhausted, like text. Rows are vertically centered per line.
///
/// ```swift
/// PRVFlowLayout(spacing: PRVSpacing.xs) {
///     ForEach(amenities) { PRVTag($0.title, systemImage: $0.icon) }
/// }
/// ```
public struct PRVFlowLayout: Layout {
    /// Horizontal spacing between items in a row.
    public var spacing: CGFloat
    /// Vertical spacing between rows.
    public var lineSpacing: CGFloat

    /// Creates a flow layout.
    /// - Parameters:
    ///   - spacing: Horizontal gap between items. Defaults to `PRVSpacing.xs`.
    ///   - lineSpacing: Vertical gap between rows. Defaults to `spacing`.
    public init(spacing: CGFloat = PRVSpacing.xs, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(fitting: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(fitting: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                let centeredY = y + (row.height - element.size.height) / 2
                subviews[element.index].place(
                    at: CGPoint(x: x, y: centeredY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(element.size)
                )
                x += element.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    // MARK: - Row computation

    private struct Row {
        var elements: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(fitting maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = current.elements.isEmpty
                ? size.width
                : current.width + spacing + size.width

            if widthIfAppended > maxWidth, !current.elements.isEmpty {
                rows.append(current)
                current = Row(
                    elements: [(index, size)],
                    width: size.width,
                    height: size.height
                )
            } else {
                current.elements.append((index, size))
                current.width = widthIfAppended
                current.height = max(current.height, size.height)
            }
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

#Preview("Flow Layout — Light") {
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        ForEach(
            ["Balayage", "Wedding Hair", "Keratin", "Gel Nails", "Lash Lift",
             "Bridal Makeup", "Color Correction", "Barber Fade"],
            id: \.self
        ) { specialty in
            PRVTag(specialty, systemImage: "sparkles")
        }
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Flow Layout — Dark") {
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        ForEach(
            ["Balayage", "Wedding Hair", "Keratin", "Gel Nails", "Lash Lift",
             "Bridal Makeup", "Color Correction", "Barber Fade"],
            id: \.self
        ) { specialty in
            PRVTag(specialty, systemImage: "sparkles")
        }
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
