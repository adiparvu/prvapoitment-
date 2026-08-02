import SwiftUI

/// A dashboard statistic tile: label, prominent value, optional trend
/// arrow, and an optional sparkline. Renders inside a Liquid Glass card so
/// tiles can be dropped straight into a grid.
///
/// ```swift
/// PRVStatTile(
///     label: "Revenue",
///     value: "€12,480",
///     trend: .up("12%"),
///     sparkline: [4, 6, 5, 8, 9, 7, 11]
/// )
/// ```
public struct PRVStatTile: View {
    /// Direction of change since the previous period, with a display delta.
    public enum Trend: Equatable, Sendable {
        /// Positive movement, e.g. `.up("12%")`.
        case up(String)
        /// Negative movement, e.g. `.down("3%")`.
        case down(String)
        /// No meaningful movement.
        case flat

        var symbol: String {
            switch self {
            case .up: "arrow.up.right"
            case .down: "arrow.down.right"
            case .flat: "minus"
            }
        }

        var tint: Color {
            switch self {
            case .up: Color.prv.success
            case .down: Color.prv.danger
            case .flat: Color.prv.textSecondary
            }
        }

        var text: String {
            switch self {
            case .up(let delta), .down(let delta): delta
            case .flat: "No change"
            }
        }

        var accessibilityText: String {
            switch self {
            case .up(let delta): "up \(delta)"
            case .down(let delta): "down \(delta)"
            case .flat: "no change"
            }
        }
    }

    private let label: String
    private let value: String
    private let trend: Trend?
    private let sparkline: [Double]

    /// Creates a stat tile.
    /// - Parameters:
    ///   - label: What the number measures, e.g. "Revenue".
    ///   - value: Pre-formatted display value, e.g. "€12,480".
    ///   - trend: Optional movement vs. the previous period.
    ///   - sparkline: Optional series rendered as a mini line chart.
    public init(
        label: String,
        value: String,
        trend: Trend? = nil,
        sparkline: [Double] = []
    ) {
        self.label = label
        self.value = value
        self.trend = trend
        self.sparkline = sparkline
    }

    public var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text(label)
                    .prvStyle(.footnote)

                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let trend {
                    HStack(spacing: PRVSpacing.xxs) {
                        Image(systemName: trend.symbol)
                            .font(.caption2.weight(.bold))
                        Text(trend.text)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(trend.tint)
                }

                if sparkline.count > 1 {
                    PRVSparkline(values: sparkline)
                        .frame(height: 28)
                        .padding(.top, PRVSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var summary = "\(label): \(value)"
        if let trend {
            summary += ", \(trend.accessibilityText)"
        }
        return summary
    }
}

/// A minimal line chart drawn from a value series — the sparkline inside
/// ``PRVStatTile``, also usable standalone in compact analytics rows.
public struct PRVSparkline: View {
    private let values: [Double]

    /// Creates a sparkline from at least two data points.
    public init(values: [Double]) {
        self.values = values
    }

    public var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(in: geometry.size)
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(
                Color.prv.accentGradient,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }

    /// Maps values into view space, top-left origin, min→bottom max→top.
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1,
              let minValue = values.min(),
              let maxValue = values.max()
        else { return [] }

        let range = maxValue - minValue
        let stepX = size.width / CGFloat(values.count - 1)

        return values.enumerated().map { index, value in
            let fraction = range > 0 ? (value - minValue) / range : 0.5
            return CGPoint(
                x: CGFloat(index) * stepX,
                y: size.height * (1 - CGFloat(fraction))
            )
        }
    }
}

#Preview("Stat Tile — Light") {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PRVSpacing.sm) {
        PRVStatTile(
            label: "Revenue",
            value: "€12,480",
            trend: .up("12%"),
            sparkline: [4, 6, 5, 8, 9, 7, 11]
        )
        PRVStatTile(
            label: "No-shows",
            value: "3",
            trend: .down("40%"),
            sparkline: [8, 6, 7, 4, 5, 3, 3]
        )
        PRVStatTile(label: "New clients", value: "27", trend: .up("8%"))
        PRVStatTile(label: "Occupancy", value: "86%", trend: .flat)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Stat Tile — Dark") {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PRVSpacing.sm) {
        PRVStatTile(
            label: "Revenue",
            value: "€12,480",
            trend: .up("12%"),
            sparkline: [4, 6, 5, 8, 9, 7, 11]
        )
        PRVStatTile(label: "Occupancy", value: "86%", trend: .flat)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
