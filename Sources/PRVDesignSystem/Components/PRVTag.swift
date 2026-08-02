import SwiftUI

/// A quiet, non-interactive tag for amenities, specialties, and other
/// metadata — an SF Symbol plus a short label on a soft surface. Lay tags
/// out with ``PRVFlowLayout`` when there are many.
///
/// ```swift
/// PRVTag("Wheelchair access", systemImage: "figure.roll")
/// PRVTag("Balayage", systemImage: "paintbrush", tint: Color.prv.accent)
/// ```
public struct PRVTag: View {
    private let title: String
    private let systemImage: String?
    private let tint: Color

    /// Creates a tag.
    /// - Parameters:
    ///   - title: The tag label.
    ///   - systemImage: Optional SF Symbol shown before the label.
    ///   - tint: Icon tint. Defaults to `Color.prv.textSecondary`.
    public init(_ title: String, systemImage: String? = nil, tint: Color = Color.prv.textSecondary) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.prv.textSecondary)
        }
        .padding(.vertical, PRVSpacing.xxs + 1)
        .padding(.horizontal, PRVSpacing.xs)
        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

#Preview("Tag — Light") {
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        PRVTag("Parking", systemImage: "car")
        PRVTag("Wi-Fi", systemImage: "wifi")
        PRVTag("Wheelchair access", systemImage: "figure.roll")
        PRVTag("Refreshments", systemImage: "cup.and.saucer")
        PRVTag("Luxury", systemImage: "sparkles", tint: Color.prv.gold)
        PRVTag("Pet friendly", systemImage: "pawprint")
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Tag — Dark") {
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        PRVTag("Parking", systemImage: "car")
        PRVTag("Wi-Fi", systemImage: "wifi")
        PRVTag("Luxury", systemImage: "sparkles", tint: Color.prv.gold)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
