import SwiftUI

/// The platform's remote image: an `AsyncImage` wrapper that shows a
/// shimmering placeholder while loading and a graceful symbol fallback on
/// failure (or when the URL is `nil`).
///
/// Bytes load through ``PRVImageStore/imageSession``, so revisiting a salon
/// hero or gallery serves from the platform's HTTP image cache instead of the
/// network.
///
/// The loaded image fills the proposed frame; callers own sizing and
/// clipping:
///
/// ```swift
/// PRVAsyncImage(url: salon.heroImageURL)
///     .frame(height: 180)
///     .clipShape(PRVRadius.shape(PRVRadius.lg))
/// ```
public struct PRVAsyncImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let url: URL?
    private let contentMode: ContentMode
    private let accessibilityLabel: String?

    /// Creates a remote image.
    /// - Parameters:
    ///   - url: The image URL. `nil` renders the failure fallback.
    ///   - contentMode: How the image fills its frame. Defaults to `.fill`
    ///     (remember to clip).
    ///   - accessibilityLabel: VoiceOver description. When `nil` the image
    ///     is treated as decorative and hidden from assistive tech.
    public init(
        url: URL?,
        contentMode: ContentMode = .fill,
        accessibilityLabel: String? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        Group {
            if let url {
                AsyncImage(
                    request: URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad),
                    transaction: Transaction(animation: reduceMotion ? nil : PRVMotion.gentle)
                ) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .transition(.opacity)
                    case .failure:
                        fallback
                    @unknown default:
                        placeholder
                    }
                }
                .asyncImageURLSession(PRVImageStore.imageSession)
            } else {
                fallback
            }
        }
        .modifier(ImageAccessibility(label: accessibilityLabel))
    }

    /// Shimmering block shown while bytes are in flight.
    private var placeholder: some View {
        Color.prv.textPrimary.opacity(0.08)
            .prvShimmer()
    }

    /// Quiet, on-brand fallback for missing or failed images.
    private var fallback: some View {
        ZStack {
            Color.prv.surface
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
        }
    }
}

/// Applies either a VoiceOver label or hides the image as decorative.
private struct ImageAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

#Preview("Async Image — Light") {
    VStack(spacing: PRVSpacing.md) {
        PRVAsyncImage(
            url: URL(string: "https://picsum.photos/seed/prv/600/400"),
            accessibilityLabel: "Salon interior"
        )
        .frame(height: 160)
        .clipShape(PRVRadius.shape(PRVRadius.lg))

        // nil URL → fallback
        PRVAsyncImage(url: nil)
            .frame(height: 120)
            .clipShape(PRVRadius.shape(PRVRadius.lg))
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Async Image — Dark") {
    VStack(spacing: PRVSpacing.md) {
        PRVAsyncImage(
            url: URL(string: "https://picsum.photos/seed/prv/600/400"),
            accessibilityLabel: "Salon interior"
        )
        .frame(height: 160)
        .clipShape(PRVRadius.shape(PRVRadius.lg))

        PRVAsyncImage(url: nil)
            .frame(height: 120)
            .clipShape(PRVRadius.shape(PRVRadius.lg))
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
