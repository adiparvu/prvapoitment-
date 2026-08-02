import SwiftUI
import PRVDesignSystem

/// A parallax hero header for profile screens. Pulling down stretches the
/// background edge-to-edge (the classic "rubber band" hero); scrolling up
/// moves it at a slower rate than the content for gentle depth. A two-stop
/// scrim keeps both the status bar and the overlay content legible over any
/// imagery.
///
/// ```swift
/// StretchyHeader(height: 340) {
///     PRVAsyncImage(url: salon.heroImageURL)
/// } overlay: {
///     Text(salon.name).prvStyle(.display)
/// }
/// ```
struct StretchyHeader<Background: View, Overlay: View>: View {
    private let height: CGFloat
    private let background: Background
    private let overlay: Overlay

    /// Creates a stretchy parallax header.
    /// - Parameters:
    ///   - height: Resting height of the hero before any stretch.
    ///   - background: Full-bleed background (image, video poster, gradient).
    ///   - overlay: Content anchored to the bottom-leading corner.
    init(
        height: CGFloat,
        @ViewBuilder background: () -> Background,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.height = height
        self.background = background()
        self.overlay = overlay()
    }

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .scrollView).minY
            let stretch = max(0, minY)

            ZStack(alignment: .bottomLeading) {
                background
                    .frame(width: proxy.size.width, height: height + stretch)
                    .clipped()

                scrim

                overlay
                    .padding(PRVSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: height + stretch)
            // Pull-down keeps the top pinned; scroll-up drifts at 35% for parallax.
            .offset(y: minY < 0 ? -minY * 0.35 : -stretch)
        }
        .frame(height: height)
    }

    /// Dual scrim: a whisper at the top for the status bar, a deep fade at
    /// the bottom so overlay text always passes contrast.
    private var scrim: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.38), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 190)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A pinned glass bar used as the sticky section header inside profile
/// scroll views. Falls back to an opaque canvas fill when Reduce
/// Transparency is enabled.
struct StickyGlassBar<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let content: Content

    /// Creates a sticky bar wrapping the given content.
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, PRVSpacing.md)
            .padding(.vertical, PRVSpacing.xs)
            .background {
                if reduceTransparency {
                    Color.prv.canvas
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
    }
}
