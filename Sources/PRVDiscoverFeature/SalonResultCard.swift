import SwiftUI
import PRVModels
import PRVDesignSystem

/// A rich search-result card: hero image with verified and category badges,
/// rating stars, location (with distance when available), amenity tags, and
/// a prominent "Book" call to action.
struct SalonResultCard: View {
    let salon: Salon
    /// Pre-formatted distance ("1.2 km"), or `nil` when no origin is known —
    /// the card shows the street address instead.
    let distanceText: String?
    let onOpen: () -> Void
    let onBook: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            onOpen()
        } label: {
            PRVGlassCard(radius: PRVRadius.xl, padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    imageHeader

                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        HStack(spacing: PRVSpacing.xs) {
                            Text(salon.name)
                                .prvStyle(.title2)
                                .lineLimit(1)
                            if salon.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.prv.accent)
                                    .accessibilityHidden(true)
                            }
                        }

                        if let tagline = salon.tagline {
                            Text(tagline)
                                .prvStyle(.subheadline)
                                .lineLimit(1)
                        }

                        HStack(spacing: PRVSpacing.xxs) {
                            PRVRatingStars(rating: salon.rating)
                            Text(ratingText)
                                .prvStyle(.caption)
                        }

                        HStack(spacing: PRVSpacing.xxs) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption)
                                .foregroundStyle(Color.prv.textSecondary)
                                .accessibilityHidden(true)
                            Text(locationText)
                                .prvStyle(.caption)
                                .lineLimit(1)
                        }

                        if !salon.amenities.isEmpty {
                            PRVFlowLayout(spacing: PRVSpacing.xxs) {
                                ForEach(salon.amenities.prefix(4), id: \.self) { amenity in
                                    PRVTag(amenity.displayName, systemImage: amenity.symbolName)
                                }
                            }
                            .padding(.top, PRVSpacing.xxs)
                        }

                        Button {
                            PRVHaptics.impact()
                            onBook()
                        } label: {
                            Text("Book")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.prvPrimary)
                        .padding(.top, PRVSpacing.xs)
                        .accessibilityLabel("Book at \(salon.name)")
                    }
                    .padding(PRVSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var imageHeader: some View {
        PRVAsyncImage(url: salon.heroImageURL)
            .frame(height: 170)
            .clipped()
            .overlay(alignment: .topLeading) {
                if let category = salon.categories.first {
                    PRVBadge(category.displayName)
                        .padding(PRVSpacing.xs)
                }
            }
            .overlay(alignment: .topTrailing) {
                if salon.isVerified {
                    PRVBadge("Verified", tint: Color.prv.success)
                        .padding(PRVSpacing.xs)
                }
            }
    }

    private var ratingText: String {
        "\(salon.rating.formatted(.number.precision(.fractionLength(1)))) (\(salon.reviewCount) reviews)"
    }

    private var locationText: String {
        if let distanceText {
            return "\(salon.address.city) · \(distanceText)"
        }
        return salon.address.oneLine
    }

    private var accessibilitySummary: String {
        "\(salon.name), rated \(salon.rating.formatted(.number.precision(.fractionLength(1)))) out of 5, \(locationText)"
    }
}

/// Loading placeholder matching the shape of ``SalonResultCard``.
struct SalonCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSkeleton(height: 170, radius: PRVRadius.lg)
            PRVSkeleton(width: 190, height: 20)
            PRVSkeleton(width: 130, height: 13)
            PRVSkeleton(width: 220, height: 13)
            PRVSkeleton(height: 46, radius: PRVRadius.md)
        }
        .padding(PRVSpacing.md)
        .accessibilityHidden(true)
    }
}

#Preview("Salon Result Card") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            SalonResultCard(
                salon: PreviewData.salonLumiere,
                distanceText: "1.2 km",
                onOpen: {},
                onBook: {}
            )
            SalonResultCard(
                salon: PreviewData.salonVelvet,
                distanceText: nil,
                onOpen: {},
                onBook: {}
            )
            SalonCardSkeleton()
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}
