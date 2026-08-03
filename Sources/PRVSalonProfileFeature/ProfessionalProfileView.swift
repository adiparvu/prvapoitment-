import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The professional's profile: photo hero with gradient scrim, title and
/// specialties, a stats row (experience, rating, response time), biography,
/// certificates, a portfolio with before/after comparisons, reviews about
/// this professional, and an availability preview with a
/// "Book with {name}" call to action.
///
/// Like the salon profile it is hero-led: the navigation bar minimizes as
/// the client scrolls into the portfolio, keeping only the pinned share
/// action visible over the photography.
public struct ProfessionalProfileView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(AppRouter.self) private var router

    @State private var model: ProfessionalProfileModel

    /// Creates the profile for one professional. All dependencies come from
    /// the environment; the initializer takes only the identifier by contract.
    public init(professionalID: Professional.ID) {
        _model = State(initialValue: ProfessionalProfileModel(professionalID: professionalID))
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
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                shareButton
            }
        }
        .task { await model.load(using: deps) }
        .confirmationDialog("Report this review?", item: $model.reviewPendingReport) { review in
            Button("Report Review", role: .destructive) {
                model.report(review)
            }
            Button("Cancel", role: .cancel) {}
        }
        .prvToast($model.toast)
    }

    // MARK: - Toolbar

    /// The single action pinned to the trailing edge, so it stays reachable
    /// while the rest of the navigation bar minimizes over the hero.
    @ViewBuilder
    private var shareButton: some View {
        if let professional = model.professional {
            ShareLink(item: model.shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel("Share \(professional.displayName)'s profile")
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private var content: some View {
        if let professional = model.professional {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    ProfessionalHeroHeader(professional: professional, salonName: model.salon?.name)

                    Group {
                        statsRow(professional)

                        if !professional.specialties.isEmpty {
                            specialtiesCard(professional)
                        }
                        if !professional.biography.isEmpty {
                            biographyCard(professional)
                        }
                        if !professional.certificates.isEmpty {
                            certificatesCard(professional)
                        }
                        if !professional.portfolio.isEmpty {
                            portfolioSection(professional)
                        }
                        availabilityCard(professional)
                        reviewsSection(professional)
                    }
                    .padding(.horizontal, PRVSpacing.md)
                }
                .padding(.bottom, PRVSpacing.xxl)
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .prvBottomBar { bookingBar(professional) }
        }
    }

    // MARK: - Stats

    /// Experience, rating, and chat response time at a glance.
    private func statsRow(_ professional: Professional) -> some View {
        HStack(spacing: PRVSpacing.sm) {
            PRVStatTile(
                label: "Experience",
                value: "\(professional.yearsOfExperience) yrs"
            )
            PRVStatTile(
                label: "Rating",
                value: ProfileFormatting.rating(professional.rating),
                trend: nil
            )
            PRVStatTile(
                label: "Responds in",
                value: professional.averageResponseMinutes.map { "~\($0) min" } ?? "—"
            )
        }
    }

    // MARK: - Specialties, biography, certificates

    private func specialtiesCard(_ professional: Professional) -> some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                sectionTitle("Specialties")
                PRVFlowLayout(spacing: PRVSpacing.xs) {
                    ForEach(professional.specialties, id: \.self) { specialty in
                        PRVTag(specialty, systemImage: "sparkles", tint: Color.prv.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func biographyCard(_ professional: Professional) -> some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                sectionTitle("About \(professional.displayName)")
                Text(professional.biography)
                    .prvStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !professional.languages.isEmpty {
                    PRVFlowLayout(spacing: PRVSpacing.xs) {
                        ForEach(professional.languages, id: \.self) { code in
                            PRVTag(ProfileFormatting.languageName(code), systemImage: "globe")
                        }
                    }
                    .padding(.top, PRVSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func certificatesCard(_ professional: Professional) -> some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                sectionTitle("Certificates")

                ForEach(professional.certificates) { certificate in
                    HStack(alignment: .top, spacing: PRVSpacing.sm) {
                        Image(systemName: "rosette")
                            .font(.body)
                            .foregroundStyle(Color.prv.gold)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(certificate.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.prv.textPrimary)
                            Text("\(certificate.issuer) · \(certificate.issuedAt.formatted(.dateTime.year()))")
                                .prvStyle(.footnote)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Portfolio

    /// Before/after items render as full-width interactive sliders; plain
    /// photos and videos fill a two-column grid beneath them.
    private func portfolioSection(_ professional: Professional) -> some View {
        let comparisons = professional.portfolio.filter { $0.kind == .beforeAfter }
        let media = professional.portfolio.filter { $0.kind != .beforeAfter }

        return VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            sectionTitle("Portfolio")

            ForEach(comparisons) { item in
                BeforeAfterSlider(
                    beforeURL: item.beforeURL,
                    afterURL: item.mediaURL,
                    caption: item.caption
                )
            }

            if !media.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: PRVSpacing.xs), count: 2),
                    spacing: PRVSpacing.xs
                ) {
                    ForEach(media) { item in
                        portfolioTile(item)
                    }
                }
            }
        }
    }

    private func portfolioTile(_ item: PortfolioItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                PRVAsyncImage(
                    url: item.mediaURL,
                    accessibilityLabel: item.caption ?? "Portfolio photo"
                )
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.prv.textOnAccent)
                        .padding(PRVSpacing.xs)
                        .accessibilityLabel("Video")
                }
            }
            .clipShape(PRVRadius.shape(PRVRadius.md))
    }

    // MARK: - Availability

    /// The professional's next three open slots; tapping one (or the CTA)
    /// heads into the booking flow for their salon.
    @ContentBuilder
    private func availabilityCard(_ professional: Professional) -> some View {
        if let salon = model.salon {
            PRVGlassCard {
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    sectionTitle("Next Availability")

                    if model.nextSlots.isEmpty {
                        Text("No open slots in the next two weeks. Start a booking to join the waitlist.")
                            .prvStyle(.subheadline)
                    } else {
                        PRVFlowLayout(spacing: PRVSpacing.xs) {
                            ForEach(model.nextSlots) { slot in
                                PRVTimeSlotPill(label: slotLabel(slot)) {
                                    startBooking(professional, salon: salon)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func slotLabel(_ slot: TimeSlot) -> String {
        slot.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: - Reviews

    private func reviewsSection(_ professional: Professional) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            sectionTitle("Reviews for \(professional.displayName)")

            if model.reviews.isEmpty {
                PRVEmptyState(
                    systemImage: "star.bubble",
                    title: "No reviews yet",
                    message: "Reviews naming \(professional.displayName) will appear here after their next appointments."
                )
            } else {
                ForEach(model.reviews) { review in
                    ReviewCard(
                        review: review,
                        responderName: model.salon?.name ?? "the salon",
                        onToggleLike: {
                            Task { await model.toggleLike(on: review, using: deps) }
                        },
                        onReport: {
                            model.reviewPendingReport = review
                        }
                    )
                }
            }
        }
    }

    // MARK: - Booking bar

    @ContentBuilder
    private func bookingBar(_ professional: Professional) -> some View {
        if let salon = model.salon {
            HStack(spacing: PRVSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(salon.name)
                        .prvStyle(.headline)
                        .lineLimit(1)
                    if let next = model.nextSlots.first {
                        Text("Next: \(slotLabel(next))")
                            .prvStyle(.caption)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: PRVSpacing.xs)

                Button("Book with \(firstName(of: professional))") {
                    startBooking(professional, salon: salon)
                }
                .buttonStyle(.prvPrimary)
                .frame(maxWidth: 190)
                .accessibilityLabel("Book with \(professional.displayName) at \(salon.name)")
            }
        }
    }

    private func startBooking(_ professional: Professional, salon: Salon) {
        PRVHaptics.impact()
        router.push(.booking(salonID: salon.id, serviceIDs: []))
    }

    /// First given name for the compact CTA, falling back to the full name.
    private func firstName(of professional: Professional) -> String {
        guard let first = professional.displayName.split(separator: " ").first else {
            return professional.displayName
        }
        return String(first)
    }

    // MARK: - Loading & failure

    private var loadingSkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                PRVSkeleton(height: 280, radius: PRVRadius.xl)
                HStack(spacing: PRVSpacing.sm) {
                    ForEach(0..<3, id: \.self) { _ in
                        PRVSkeleton(height: 84, radius: PRVRadius.lg)
                    }
                }
                PRVSkeleton(width: 180, height: 18)
                PRVSkeleton(height: 120, radius: PRVRadius.lg)
            }
            .padding(PRVSpacing.md)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading profile")
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "wifi.exclamationmark",
            title: "Couldn't load this profile",
            message: message,
            actionTitle: "Try Again"
        ) {
            Task { await model.load(using: deps) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Shared

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .prvStyle(.title2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero

/// The professional's parallax hero: portrait photo (or brand-gradient
/// initials fallback) with scrim, name, title, and salon affiliation.
struct ProfessionalHeroHeader: View {
    let professional: Professional
    let salonName: String?

    var body: some View {
        StretchyHeader(height: 300) {
            if professional.photoURL != nil {
                PRVAsyncImage(url: professional.photoURL)
            } else {
                ZStack {
                    Color.prv.accentGradient
                    PRVAvatar(
                        name: professional.displayName,
                        size: .custom(140)
                    )
                }
            }
        } overlay: {
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(professional.displayName)
                    .prvStyle(.display)
                    .foregroundStyle(Color.prv.textOnAccent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                Text(professional.title)
                    .font(.headline)
                    .foregroundStyle(Color.prv.textOnAccent.opacity(0.92))

                HStack(spacing: PRVSpacing.xs) {
                    PRVRatingStars(rating: professional.rating)
                    Text("\(ProfileFormatting.rating(professional.rating)) · \(professional.reviewCount) reviews")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textOnAccent.opacity(0.92))
                }

                if let salonName {
                    HStack(spacing: PRVSpacing.xxs) {
                        Image(systemName: "building.2.fill")
                            .font(.caption)
                        Text(salonName)
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(Color.prv.textOnAccent.opacity(0.85))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(heroAccessibilityLabel)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private var heroAccessibilityLabel: String {
        var label = "\(professional.displayName), \(professional.title)"
        label += ", rated \(ProfileFormatting.rating(professional.rating)) out of 5"
        if let salonName { label += ", at \(salonName)" }
        return label
    }
}

// MARK: - Previews

#Preview("Professional Profile") {
    NavigationStack {
        ProfessionalProfileView(professionalID: PreviewData.stylistAmelie.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Professional Profile — Dark") {
    NavigationStack {
        ProfessionalProfileView(professionalID: PreviewData.artistNoor.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
