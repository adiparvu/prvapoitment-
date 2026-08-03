import SwiftUI

/// Sweeps a soft highlight band across the modified view — the platform's
/// loading shimmer. The gradient is masked by the content itself so any
/// shape (text, blocks, avatars) shimmers within its own silhouette.
///
/// Respects Reduce Motion: when enabled the view renders statically with no
/// moving highlight. The sweep also stops in windows that aren't active
/// (iPad multi-window and Stage Manager), so a background window never
/// animates for attention it can't have — the placeholder simply rests.
///
/// ```swift
/// PRVSkeleton(height: 16).prvShimmer()
/// ```
public struct PRVShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var phase: CGFloat = -0.35

    private let isActive: Bool

    /// Creates a shimmer modifier.
    /// - Parameter isActive: Pass `false` to render the content untouched
    ///   (useful for binding shimmer to a loading flag).
    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !reduceMotion && appearsActive {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: phase - 0.35),
                            .init(color: .white.opacity(0.55), location: phase),
                            .init(color: .clear, location: phase + 0.35),
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        // Restart from the leading edge every time the
                        // shimmer becomes active.
                        phase = -0.35
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            phase = 1.35
                        }
                    }
                }
            }
    }
}

extension View {
    /// Applies the PRV loading shimmer while `active` is `true`.
    /// Honors Reduce Motion by rendering statically, and pauses while the
    /// window is inactive.
    public func prvShimmer(_ active: Bool = true) -> some View {
        modifier(PRVShimmerModifier(isActive: active))
    }
}

#Preview("Shimmer — Light") {
    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
        PRVSkeleton(height: 120, radius: PRVRadius.lg)
        PRVSkeleton(width: 220, height: 18)
        PRVSkeleton(width: 140, height: 14)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Shimmer — Dark") {
    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
        PRVSkeleton(height: 120, radius: PRVRadius.lg)
        PRVSkeleton(width: 220, height: 18)
        PRVSkeleton(width: 140, height: 14)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
