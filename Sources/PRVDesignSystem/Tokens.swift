import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color tokens

/// Semantic color palette. Features never hard-code colors — always `Color.prv.*`.
public struct PRVColors: Sendable {
    /// Signature brand gradient endpoints — a warm rose-gold into deep orchid.
    public let accent = Color(red: 0.78, green: 0.35, blue: 0.56)
    public let accentSecondary = Color(red: 0.94, green: 0.62, blue: 0.48)
    public let gold = Color(red: 0.85, green: 0.68, blue: 0.38)

    // Backgrounds layer from canvas (deepest) to elevated surfaces.
    public let canvas = Color(uiColor: .systemBackground)
    public let surface = Color(uiColor: .secondarySystemBackground)
    public let surfaceElevated = Color(uiColor: .tertiarySystemBackground)

    public let textPrimary = Color.primary
    public let textSecondary = Color.secondary
    public let textOnAccent = Color.white

    public let success = Color(red: 0.22, green: 0.68, blue: 0.48)
    public let warning = Color(red: 0.95, green: 0.65, blue: 0.20)
    public let danger = Color(red: 0.88, green: 0.28, blue: 0.32)

    public let separator = Color(uiColor: .separator)

    /// The signature brand gradient used for hero moments and primary CTAs.
    public var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    /// Namespace for PRV semantic colors: `Color.prv.accent`.
    public static let prv = PRVColors()
}

// MARK: - Spacing (4-pt grid)

public enum PRVSpacing {
    /// 4
    public static let xxs: CGFloat = 4
    /// 8
    public static let xs: CGFloat = 8
    /// 12
    public static let sm: CGFloat = 12
    /// 16
    public static let md: CGFloat = 16
    /// 20
    public static let lg: CGFloat = 20
    /// 24
    public static let xl: CGFloat = 24
    /// 32
    public static let xxl: CGFloat = 32
    /// 44
    public static let xxxl: CGFloat = 44
}

// MARK: - Corner radii (continuous, Apple-style)

public enum PRVRadius {
    /// 10 — chips, small controls
    public static let sm: CGFloat = 10
    /// 16 — buttons, inputs
    public static let md: CGFloat = 16
    /// 22 — cards
    public static let lg: CGFloat = 22
    /// 30 — hero cards, sheets
    public static let xl: CGFloat = 30

    public static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - Shadows

public enum PRVShadow {
    /// Soft ambient shadow for floating cards.
    public static func soft(_ view: some View) -> some View {
        view.shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 8)
    }
}

extension View {
    /// Soft, layered depth shadow for floating glass surfaces.
    public func prvSoftShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.06), radius: 28, x: 0, y: 12)
    }
}
