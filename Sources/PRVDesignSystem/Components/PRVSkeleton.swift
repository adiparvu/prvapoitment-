import SwiftUI

/// A shimmering placeholder block shown while real content loads.
/// Give it a fixed `width` for text-like lines, or leave `width` `nil`
/// to fill the proposed width (cards, images).
///
/// ```swift
/// VStack(alignment: .leading, spacing: PRVSpacing.xs) {
///     PRVSkeleton(height: 140, radius: PRVRadius.lg)   // hero image
///     PRVSkeleton(width: 180, height: 16)              // title line
///     PRVSkeleton(width: 120, height: 12)              // subtitle line
/// }
/// ```
public struct PRVSkeleton: View {
    private let width: CGFloat?
    private let height: CGFloat
    private let radius: CGFloat

    /// Creates a skeleton block.
    /// - Parameters:
    ///   - width: Fixed width, or `nil` to fill available width.
    ///   - height: Block height. Defaults to a body-text line height.
    ///   - radius: Continuous corner radius. Defaults to `PRVRadius.sm`.
    public init(
        width: CGFloat? = nil,
        height: CGFloat = 16,
        radius: CGFloat = PRVRadius.sm
    ) {
        self.width = width
        self.height = height
        self.radius = radius
    }

    public var body: some View {
        PRVRadius.shape(radius)
            .fill(Color.prv.textPrimary.opacity(0.08))
            .frame(width: width, height: height)
            .prvShimmer()
            .accessibilityHidden(true)
    }
}

extension View {
    /// Redacts the view and overlays the PRV shimmer while `isLoading` is
    /// `true` — the one-line way to turn any populated layout into its own
    /// loading skeleton. Hit testing is disabled while loading.
    ///
    /// ```swift
    /// SalonCard(salon: salon ?? .placeholderShape)
    ///     .prvSkeleton(when: model.isLoading)
    /// ```
    public func prvSkeleton(when isLoading: Bool) -> some View {
        redacted(reason: isLoading ? .placeholder : [])
            .prvShimmer(isLoading)
            .allowsHitTesting(!isLoading)
            .accessibilityHidden(isLoading)
    }
}

#Preview("Skeleton — Light") {
    VStack(alignment: .leading, spacing: PRVSpacing.md) {
        PRVSkeleton(height: 160, radius: PRVRadius.lg)
        PRVSkeleton(width: 200, height: 18)
        PRVSkeleton(width: 130, height: 13)

        Divider().padding(.vertical, PRVSpacing.sm)

        // Redacting an already-built layout.
        HStack(spacing: PRVSpacing.sm) {
            PRVAvatar(name: "Sofia Laurent", size: .medium)
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text("Sofia Laurent").prvStyle(.headline)
                Text("Premium member").prvStyle(.subheadline)
            }
        }
        .prvSkeleton(when: true)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Skeleton — Dark") {
    VStack(alignment: .leading, spacing: PRVSpacing.md) {
        PRVSkeleton(height: 160, radius: PRVRadius.lg)
        PRVSkeleton(width: 200, height: 18)
        PRVSkeleton(width: 130, height: 13)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
