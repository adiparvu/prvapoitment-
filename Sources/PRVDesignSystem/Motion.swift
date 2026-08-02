import SwiftUI

/// Motion tokens. All feature animation goes through these so Reduce Motion
/// is honored in one place.
public enum PRVMotion {
    /// Standard interactive spring — snappy, natural.
    public static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Gentle spring for large surfaces (sheets, hero cards).
    public static let gentle = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// Quick response for small state changes (toggles, likes).
    public static let quick = Animation.spring(response: 0.25, dampingFraction: 0.9)
    /// Liquid morph for glass transitions.
    public static let morph = Animation.smooth(duration: 0.45)
}

extension View {
    /// Animates with the given PRV motion unless Reduce Motion is on.
    public func prvAnimation(_ animation: Animation, value: some Equatable) -> some View {
        modifier(ReduceMotionAwareAnimation(animation: animation, value: value))
    }
}

private struct ReduceMotionAwareAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
