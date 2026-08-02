import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The salon profile: a parallax hero (image or video poster with gradient
/// scrim, name, verified seal, rating, and category tags), a sticky glass
/// segmented control switching between Services, Team, Gallery, About, and
/// Reviews, and a floating glass "Book Now" bar that carries the client's
/// service selection into the booking flow.
///
/// Data flows exclusively through `@Environment(\.prvDependencies)`;
/// cross-feature navigation goes through the shared `AppRouter`.
public struct SalonProfileView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(AppRouter.self) private var router

    @State private var model: SalonProfileModel

    /// Creates the profile for one salon. All dependencies come from the
    /// environment; the initializer takes only the identifier by contract.
    public init(salonID: Salon.ID) {
        _model = State(initialValue: SalonProfileModel(salonID: salonID))
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .loading:
                loadingSkeleton
            case .failed(let message):
                failureState(message)
            case .loaded:
                content
            }
        }
        .background(Color.prv.canvas)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(using: deps) }
        .sheet(isPresented: $model.isWritingReview) {
            WriteReviewSheet(model: model, salonName: model.salon?.name ?? "")
        }
        .prvToast($model.toast)
    }

    // MARK: - Loaded content

    @ViewBuilder
    private var content: some View {
        if let salon = model.salon {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    SalonHeroHeader(salon: salon)

                    Section {
                        sectionContent(salon: salon)
                            .padding(.horizontal, PRVSpacing.md)
                            .padding(.top, PRVSpacing.md)
                            .padding(.bottom, PRVSpacing.xxl)
                    } header: {
                        StickyGlassBar {
                            PRVSegmentedGlassControl(
                                selection: $model.section,
                                options: SalonProfileSection.allCases,
                                title: \.title
                            )
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .prvAnimation(PRVMotion.spring, value: model.section)
            .prvBottomBar { bookingBar(salon: salon) }
        }
    }

    /// The active section's content. Switching sections cross-fades with a
    /// gentle vertical settle.
    @ViewBuilder
    private func sectionContent(salon: Salon) -> some View {
        Group {
            switch model.section {
            case .services:
                ServicesSectionView(model: model)
            case .team:
                TeamSectionView(professionals: model.professionals)
            case .gallery:
                GallerySectionView(salon: salon)
            case .about:
                AboutSectionView(salon: salon)
            case .reviews:
                ReviewsSectionView(model: model, salon: salon)
            }
        }
        .transition(.opacity.combined(with: .offset(y: PRVSpacing.xs)))
        .id(model.section)
    }

    // MARK: - Booking bar

    /// Floating glass bar summarizing the selection and launching the
    /// booking flow with the chosen services.
    private func bookingBar(salon: Salon) -> some View {
        HStack(spacing: PRVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                if let total = model.totalPrice {
                    Text(selectionSummary)
                        .prvStyle(.caption)
                        .lineLimit(1)
                    PRVPriceLabel(total.formatted, emphasis: .prominent)
                } else {
                    Text(salon.name)
                        .prvStyle(.headline)
                        .lineLimit(1)
                    Text("Pick services, or book and choose later")
                        .prvStyle(.caption)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            Button("Book Now") {
                PRVHaptics.impact()
                router.push(.booking(
                    salonID: salon.id,
                    serviceIDs: model.selectedServices.map(\.id)
                ))
            }
            .buttonStyle(.prvPrimary)
            .frame(maxWidth: 150)
            .accessibilityLabel(bookAccessibilityLabel(salon: salon))
        }
        .prvAnimation(PRVMotion.quick, value: model.selectedCount)
    }

    private var selectionSummary: String {
        let count = model.selectedCount
        let services = count == 1 ? "1 service" : "\(count) services"
        return "\(services) · \(ProfileFormatting.duration(model.totalDurationMinutes))"
    }

    private func bookAccessibilityLabel(salon: Salon) -> String {
        guard let total = model.totalPrice else {
            return "Book at \(salon.name)"
        }
        return "Book \(selectionSummary) at \(salon.name), total \(total.formatted)"
    }

    // MARK: - Loading & failure

    /// Redacted shimmer layout shown during the initial load.
    private var loadingSkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                PRVSkeleton(height: 300, radius: PRVRadius.xl)
                PRVSkeleton(width: 220, height: 24)
                PRVSkeleton(width: 150, height: 14)
                ForEach(0..<4, id: \.self) { _ in
                    PRVSkeleton(height: 88, radius: PRVRadius.lg)
                }
            }
            .padding(PRVSpacing.md)
        }
        .scrollDisabled(true)
        .accessibilityLabel("Loading salon")
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "wifi.exclamationmark",
            title: "Couldn't load this salon",
            message: message,
            actionTitle: "Try Again"
        ) {
            Task { await model.load(using: deps) }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Hero

/// The salon's parallax hero: image (or video poster) with scrim, category
/// tags, name with verified seal, and the rating line.
struct SalonHeroHeader: View {
    let salon: Salon

    var body: some View {
        StretchyHeader(height: 340) {
            ZStack(alignment: .topTrailing) {
                PRVAsyncImage(url: salon.heroImageURL ?? salon.galleryURLs.first)

                if salon.heroVideoURL != nil {
                    videoBadge
                }
            }
        } overlay: {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                categoryTags

                HStack(spacing: PRVSpacing.xs) {
                    Text(salon.name)
                        .prvStyle(.display)
                        .foregroundStyle(Color.prv.textOnAccent)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    if salon.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(Color.prv.gold)
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: PRVSpacing.xs) {
                    PRVRatingStars(rating: salon.rating)
                    Text("\(ProfileFormatting.rating(salon.rating)) · \(salon.reviewCount) reviews")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textOnAccent.opacity(0.92))
                }

                if let tagline = salon.tagline {
                    Text(tagline)
                        .font(.subheadline)
                        .foregroundStyle(Color.prv.textOnAccent.opacity(0.85))
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(heroAccessibilityLabel)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// Category chips floating on the imagery.
    private var categoryTags: some View {
        HStack(spacing: PRVSpacing.xxs) {
            ForEach(salon.categories, id: \.self) { category in
                HStack(spacing: PRVSpacing.xxs) {
                    Image(systemName: category.symbolName)
                        .font(.caption2.weight(.semibold))
                    Text(category.displayName)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.prv.textOnAccent)
                .padding(.vertical, PRVSpacing.xxs)
                .padding(.horizontal, PRVSpacing.xs)
                .prvGlassEffect()
            }
        }
    }

    /// Placeholder affordance signalling a hero video is available.
    private var videoBadge: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: "play.fill")
                .font(.caption2)
            Text("Video")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.prv.textOnAccent)
        .padding(.vertical, PRVSpacing.xxs)
        .padding(.horizontal, PRVSpacing.xs)
        .prvGlassEffect()
        .padding(.top, PRVSpacing.xxxl + PRVSpacing.lg)
        .padding(.trailing, PRVSpacing.md)
        .accessibilityLabel("Video tour available")
    }

    private var heroAccessibilityLabel: String {
        var label = salon.name
        if salon.isVerified { label += ", verified" }
        label += ", rated \(ProfileFormatting.rating(salon.rating)) out of 5"
        label += ", \(salon.reviewCount) reviews"
        return label
    }
}

// MARK: - Previews

#Preview("Salon Profile") {
    NavigationStack {
        SalonProfileView(salonID: PreviewData.salonLumiere.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Salon Profile — Dark") {
    NavigationStack {
        SalonProfileView(salonID: PreviewData.salonVelvet.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
