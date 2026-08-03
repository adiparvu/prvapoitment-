import SwiftUI

/// The platform's signature surface: a floating Liquid Glass card with
/// layered depth, continuous corners, and graceful accessibility fallbacks.
public struct PRVGlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let radius: CGFloat
    private let padding: CGFloat
    private let content: Content

    public init(
        radius: CGFloat = PRVRadius.lg,
        padding: CGFloat = PRVSpacing.md,
        @ViewBuilder content: () -> Content
    ) {
        self.radius = radius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background {
                if reduceTransparency {
                    PRVRadius.shape(radius).fill(Color.prv.surface)
                } else {
                    PRVRadius.shape(radius).fill(.ultraThinMaterial)
                }
            }
            .clipShape(PRVRadius.shape(radius))
            .overlay {
                PRVRadius.shape(radius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .prvSoftShadow()
    }
}

extension View {
    /// Wraps any view in the signature Liquid Glass card treatment.
    public func prvGlassCard(
        radius: CGFloat = PRVRadius.lg,
        padding: CGFloat = PRVSpacing.md
    ) -> some View {
        PRVGlassCard(radius: radius, padding: padding) { self }
    }

    /// Applies the Liquid Glass effect to a control.
    ///
    /// `interactive` opts the surface into the reactive treatment — glass that
    /// scales, bounces, and shimmers under touch — which suits controls but
    /// not static chrome. The deployment target is iOS 27, so no availability
    /// fallback is needed; the SDK renders the current Liquid Glass material.
    public func prvGlassEffect(interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular)
    }
}

// MARK: - Buttons

/// Primary call-to-action: brand gradient fill, white text, springy press.
public struct PRVPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.prv.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, PRVSpacing.md)
            .background(Color.prv.accentGradient, in: PRVRadius.shape(PRVRadius.md))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(PRVMotion.quick, value: configuration.isPressed)
    }
}

/// Secondary action: glass capsule with subtle border.
public struct PRVGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.prv.textPrimary)
            .padding(.vertical, PRVSpacing.sm)
            .padding(.horizontal, PRVSpacing.lg)
            .background {
                if reduceTransparency {
                    Capsule().fill(Color.prv.surface)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(PRVMotion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PRVPrimaryButtonStyle {
    /// `Button("Book Now") {}.buttonStyle(.prvPrimary)`
    public static var prvPrimary: PRVPrimaryButtonStyle { PRVPrimaryButtonStyle() }
}

extension ButtonStyle where Self == PRVGlassButtonStyle {
    /// `Button("See All") {}.buttonStyle(.prvGlass)`
    public static var prvGlass: PRVGlassButtonStyle { PRVGlassButtonStyle() }
}
