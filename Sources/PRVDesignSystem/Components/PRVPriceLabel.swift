import SwiftUI

/// Displays a price with optional "from" prefix (starting prices) and an
/// optional struck-through original price (discounts). Takes pre-formatted
/// strings so it stays model-agnostic — pass `Money.formatted` from feature
/// code:
///
/// ```swift
/// PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
/// PRVPriceLabel(discounted.formatted, originalPrice: full.formatted)
/// ```
public struct PRVPriceLabel: View {
    /// Visual prominence of the price.
    public enum Emphasis: Sendable {
        /// Inline metadata, e.g. inside a service row.
        case standard
        /// Hero price, e.g. checkout total.
        case prominent

        var font: Font {
            switch self {
            case .standard: .headline
            case .prominent: .system(.title, design: .rounded, weight: .bold)
            }
        }
    }

    private let price: String
    private let isFrom: Bool
    private let originalPrice: String?
    private let emphasis: Emphasis

    /// Creates a price label.
    /// - Parameters:
    ///   - price: Pre-formatted price string, e.g. `"€45.00"` (`Money.formatted`).
    ///   - isFrom: When `true`, shows a "from" prefix for starting prices.
    ///   - originalPrice: Optional pre-discount price rendered struck through.
    ///   - emphasis: Visual prominence. Defaults to `.standard`.
    public init(
        _ price: String,
        isFrom: Bool = false,
        originalPrice: String? = nil,
        emphasis: Emphasis = .standard
    ) {
        self.price = price
        self.isFrom = isFrom
        self.originalPrice = originalPrice
        self.emphasis = emphasis
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xxs) {
            if isFrom {
                Text("from")
                    .font(.footnote)
                    .foregroundStyle(Color.prv.textSecondary)
            }
            Text(price)
                .font(emphasis.font)
                .foregroundStyle(Color.prv.textPrimary)
            if let originalPrice {
                Text(originalPrice)
                    .font(.footnote)
                    .strikethrough()
                    .foregroundStyle(Color.prv.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = isFrom ? "from \(price)" : price
        if let originalPrice {
            text += ", was \(originalPrice)"
        }
        return text
    }
}

#Preview("Price Label — Light") {
    VStack(alignment: .leading, spacing: PRVSpacing.md) {
        PRVPriceLabel("€45.00")
        PRVPriceLabel("€120.00", isFrom: true)
        PRVPriceLabel("€76.50", originalPrice: "€90.00")
        PRVPriceLabel("€196.50", emphasis: .prominent)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Price Label — Dark") {
    VStack(alignment: .leading, spacing: PRVSpacing.md) {
        PRVPriceLabel("€120.00", isFrom: true)
        PRVPriceLabel("€76.50", originalPrice: "€90.00")
        PRVPriceLabel("€196.50", emphasis: .prominent)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
