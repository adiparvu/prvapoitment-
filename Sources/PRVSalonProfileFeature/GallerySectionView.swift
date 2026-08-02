import SwiftUI
import PRVModels
import PRVDesignSystem

/// The Gallery section: a photo grid plus social presence rows (Instagram,
/// TikTok) and a 360° virtual-tour link when the salon offers one.
struct GallerySectionView: View {
    @Environment(\.openURL) private var openURL

    let salon: Salon

    private var hasSocialLinks: Bool {
        salon.instagramHandle != nil || salon.tikTokHandle != nil || salon.virtualTourURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            if salon.galleryURLs.isEmpty && !hasSocialLinks {
                PRVEmptyState(
                    systemImage: "photo.on.rectangle.angled",
                    title: "No photos yet",
                    message: "This salon hasn't added gallery photos. Their latest work will appear here."
                )
            } else {
                if !salon.galleryURLs.isEmpty {
                    photoGrid
                } else {
                    PRVEmptyState(
                        systemImage: "photo.on.rectangle.angled",
                        title: "No photos yet",
                        message: "Follow the salon's social channels below for their latest work."
                    )
                }

                if hasSocialLinks {
                    socialLinks
                }
            }
        }
    }

    // MARK: - Photo grid

    private var photoGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: PRVSpacing.xs), count: 3),
            spacing: PRVSpacing.xs
        ) {
            ForEach(Array(salon.galleryURLs.enumerated()), id: \.offset) { index, url in
                SquareGalleryTile(
                    url: url,
                    accessibilityLabel: "Gallery photo \(index + 1) of \(salon.galleryURLs.count)"
                )
            }
        }
    }

    // MARK: - Social & tour links

    private var socialLinks: some View {
        PRVGlassCard {
            VStack(spacing: PRVSpacing.xs) {
                if let handle = salon.instagramHandle {
                    socialRow(
                        title: "@\(normalized(handle))",
                        subtitle: "Instagram",
                        systemImage: "camera.fill",
                        url: URL(string: "https://instagram.com/\(normalized(handle))")
                    )
                }

                if let handle = salon.tikTokHandle {
                    if salon.instagramHandle != nil { Divider() }
                    socialRow(
                        title: "@\(normalized(handle))",
                        subtitle: "TikTok",
                        systemImage: "music.note",
                        url: URL(string: "https://tiktok.com/@\(normalized(handle))")
                    )
                }

                if let tourURL = salon.virtualTourURL {
                    if salon.instagramHandle != nil || salon.tikTokHandle != nil { Divider() }
                    socialRow(
                        title: "Virtual tour",
                        subtitle: "Walk through the salon in 360°",
                        systemImage: "binoculars.fill",
                        url: tourURL
                    )
                }
            }
        }
    }

    /// A tappable link row that opens the destination in the browser.
    @ViewBuilder
    private func socialRow(title: String, subtitle: String, systemImage: String, url: URL?) -> some View {
        Button {
            PRVHaptics.tap()
            if let url { openURL(url) }
        } label: {
            PRVListRow(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(subtitle): \(title)")
        .accessibilityHint("Opens in your browser")
        .accessibilityAddTraits(.isLink)
    }

    /// Strips a leading "@" so stored handles work whether or not the salon
    /// typed one.
    private func normalized(_ handle: String) -> String {
        handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
    }
}

/// A square, clipped gallery cell that keeps its aspect ratio at any width.
struct SquareGalleryTile: View {
    let url: URL
    let accessibilityLabel: String

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                PRVAsyncImage(url: url, accessibilityLabel: accessibilityLabel)
            }
            .clipShape(PRVRadius.shape(PRVRadius.sm))
    }
}

#Preview("Gallery Section") {
    ScrollView {
        GallerySectionView(
            salon: {
                var salon = PreviewData.salonLumiere
                salon.galleryURLs = (1...7).compactMap {
                    URL(string: "https://picsum.photos/seed/prv\($0)/400")
                }
                salon.instagramHandle = "maisonlumiere"
                salon.tikTokHandle = "maisonlumiere"
                salon.virtualTourURL = URL(string: "https://example.com/tour")
                return salon
            }()
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}
