import SwiftUI
import PRVDesignSystem

/// Ambient animated brand backdrop used behind the welcome and onboarding
/// experiences: softly drifting accent-gradient orbs blurred over the canvas.
/// Motion is disabled automatically when Reduce Motion is on, and the view is
/// hidden from assistive technologies because it is purely decorative.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            Color.prv.canvas

            orb(color: Color.prv.accent, size: 360)
                .offset(x: drift ? -90 : 60, y: drift ? -180 : -260)

            orb(color: Color.prv.accentSecondary, size: 300)
                .offset(x: drift ? 120 : -40, y: drift ? 40 : -60)

            orb(color: Color.prv.gold, size: 260)
                .offset(x: drift ? -70 : 90, y: drift ? 300 : 240)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private func orb(color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(0.26))
            .frame(width: size, height: size)
            .blur(radius: 70)
            .allowsHitTesting(false)
    }
}

#Preview("Aurora backdrop") {
    AuroraBackground()
}
