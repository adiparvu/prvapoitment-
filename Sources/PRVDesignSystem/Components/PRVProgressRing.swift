import SwiftUI

/// An animated circular progress ring stroked with the brand gradient,
/// with optional custom center content (a percentage, an icon, a tier
/// emblem…). Progress changes animate with a gentle spring unless Reduce
/// Motion is on.
///
/// ```swift
/// PRVProgressRing(progress: loyaltyProgress) {
///     Text(loyaltyProgress.formatted(.percent.precision(.fractionLength(0))))
///         .prvStyle(.headline)
/// }
/// ```
public struct PRVProgressRing<Center: View>: View {
    private let progress: Double
    private let lineWidth: CGFloat
    private let size: CGFloat
    private let tint: AnyShapeStyle
    private let center: Center

    /// Creates a progress ring with custom center content.
    /// - Parameters:
    ///   - progress: Completion fraction, clamped to 0…1.
    ///   - lineWidth: Ring stroke width. Defaults to 8.
    ///   - size: Ring diameter in points. Defaults to 72.
    ///   - tint: Stroke style for the progress arc. Defaults to the brand gradient.
    ///   - center: Content shown inside the ring.
    public init(
        progress: Double,
        lineWidth: CGFloat = 8,
        size: CGFloat = 72,
        tint: some ShapeStyle = Color.prv.accentGradient,
        @ViewBuilder center: () -> Center
    ) {
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        self.lineWidth = lineWidth
        self.size = size
        self.tint = AnyShapeStyle(tint)
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.prv.separator.opacity(0.4), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            center
        }
        .frame(width: size, height: size)
        .prvAnimation(PRVMotion.gentle, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
    }
}

extension PRVProgressRing where Center == EmptyView {
    /// Creates a progress ring with no center content.
    public init(
        progress: Double,
        lineWidth: CGFloat = 8,
        size: CGFloat = 72,
        tint: some ShapeStyle = Color.prv.accentGradient
    ) {
        self.init(progress: progress, lineWidth: lineWidth, size: size, tint: tint) {
            EmptyView()
        }
    }
}

#Preview("Progress Ring — Light") {
    @Previewable @State var progress = 0.68
    VStack(spacing: PRVSpacing.xl) {
        HStack(spacing: PRVSpacing.xl) {
            PRVProgressRing(progress: progress) {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
            }
            PRVProgressRing(progress: 0.35, lineWidth: 6, size: 56)
            PRVProgressRing(progress: 1.0, size: 56, tint: Color.prv.gold) {
                Image(systemName: "crown.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.prv.gold)
            }
        }
        Button("Randomize") { progress = .random(in: 0...1) }
            .buttonStyle(.prvGlass)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Progress Ring — Dark") {
    HStack(spacing: PRVSpacing.xl) {
        PRVProgressRing(progress: 0.68) {
            Text("68%")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Color.prv.textPrimary)
        }
        PRVProgressRing(progress: 0.35, lineWidth: 6, size: 56)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
