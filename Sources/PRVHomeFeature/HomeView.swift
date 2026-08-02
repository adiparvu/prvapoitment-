import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The personalized client home: greeting header with notification bell,
/// upcoming-appointment hero with a live countdown, discovery rails
/// ("For You", "Nearby", "Recently Viewed"), loyalty status, active offers,
/// a Beauty Wallet snapshot, and the AI assistant entry point.
///
/// Every section loads concurrently and independently — a slow repository
/// shows its own skeleton, a failing one an inline retry — so the screen is
/// always alive. Data access goes exclusively through
/// `@Environment(\.prvDependencies)`; cross-feature navigation through the
/// shared `AppRouter`.
public struct HomeView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var model = HomeModel()

    /// Creates the home screen. All dependencies come from the environment;
    /// the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                header
                    .padding(.horizontal, PRVSpacing.lg)

                heroSection
                    .padding(.horizontal, PRVSpacing.lg)

                salonRail(
                    "For You",
                    subtitle: "Trending with clients like you",
                    phase: model.trendingPhase
                )

                salonRail(
                    "Nearby",
                    subtitle: "Great work around the corner",
                    phase: model.nearbyPhase
                )

                salonRail(
                    "Recently Viewed",
                    subtitle: nil,
                    phase: model.recentlyViewedPhase
                )

                loyaltySection
                    .padding(.horizontal, PRVSpacing.lg)

                packagesSection

                walletSection
                    .padding(.horizontal, PRVSpacing.lg)

                AssistantEntryCard {
                    router.push(.beautyAssistant)
                }
                .padding(.horizontal, PRVSpacing.lg)
            }
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .prvAnimation(PRVMotion.gentle, value: model.hasLoadedOnce)
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) {
            await model.load(for: session.currentUser, using: deps)
        }
    }

    // MARK: - Header

    /// Time-of-day greeting, avatar, and the notification bell with its
    /// unread badge.
    private var header: some View {
        HStack(spacing: PRVSpacing.sm) {
            PRVAvatar(
                name: session.currentUser?.fullName ?? "Guest",
                imageURL: session.currentUser?.avatarURL,
                size: .medium
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .prvStyle(.footnote)
                Text(session.currentUser?.firstName ?? "Welcome")
                    .prvStyle(.title)
                    .lineLimit(1)
            }

            Spacer(minLength: PRVSpacing.xs)

            notificationBell
        }
    }

    private var notificationBell: some View {
        Button {
            PRVHaptics.tap()
            router.push(.notifications)
        } label: {
            Image(systemName: "bell.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.prv.textPrimary)
                .frame(width: 44, height: 44)
                .prvGlassEffect(interactive: true)
                .overlay(alignment: .topTrailing) {
                    PRVBadge(count: model.unreadNotificationCount)
                        .offset(x: 4, y: -4)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            model.unreadNotificationCount > 0
                ? "Notifications, \(model.unreadNotificationCount) unread"
                : "Notifications"
        )
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        switch model.heroPhase {
        case .loading:
            HeroSkeleton()
        case .failed(let message):
            HomeSectionErrorCard(message: message) { reload() }
        case .unavailable:
            EmptyView()
        case .loaded(let hero):
            if let hero {
                UpcomingAppointmentCard(
                    hero: hero,
                    onOpen: { router.push(.appointment(hero.appointment.id)) },
                    onDirections: { openDirections(for: hero) },
                    onReschedule: { router.push(.appointment(hero.appointment.id)) }
                )
            } else if session.isAuthenticated {
                emptyHeroCard
            }
        }
    }

    /// Friendly nudge shown when nothing is booked yet.
    private var emptyHeroCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            HStack(spacing: PRVSpacing.md) {
                Image(systemName: "calendar.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.prv.accentGradient)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text("Nothing on the books")
                        .prvStyle(.headline)
                    Text("Your next great hair day is one tap away.")
                        .prvStyle(.footnote)
                }

                Spacer(minLength: PRVSpacing.xs)

                Button {
                    PRVHaptics.tap()
                    router.selectedTab = .discover
                } label: {
                    Text("Explore")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                }
                .accessibilityLabel("Explore salons")
            }
        }
    }

    /// Opens Apple Maps with directions to the appointment's salon.
    private func openDirections(for hero: HomeModel.UpcomingHero) {
        var components = URLComponents(string: "https://maps.apple.com/")
        if let coordinate = hero.salon?.address.coordinate {
            components?.queryItems = [
                URLQueryItem(name: "daddr", value: "\(coordinate.latitude),\(coordinate.longitude)")
            ]
        } else {
            components?.queryItems = [
                URLQueryItem(name: "q", value: hero.appointment.salonName)
            ]
        }
        if let url = components?.url {
            openURL(url)
        }
    }

    // MARK: - Salon rails

    /// A horizontal rail of salon cards driven by one section phase.
    /// Empty rails disappear entirely instead of rendering a hole.
    @ViewBuilder
    private func salonRail(
        _ title: String,
        subtitle: String?,
        phase: HomeSectionPhase<[Salon]>
    ) -> some View {
        switch phase {
        case .unavailable:
            EmptyView()
        case .loading:
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(title, subtitle: subtitle)
                    .padding(.horizontal, PRVSpacing.lg)
                RailSkeleton()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(title, subtitle: subtitle)
                    .padding(.horizontal, PRVSpacing.lg)
                HomeSectionErrorCard(message: message) { reload() }
                    .padding(.horizontal, PRVSpacing.lg)
            }
        case .loaded(let salons):
            if salons.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    PRVSectionHeader(title, subtitle: subtitle, actionTitle: "See All") {
                        router.selectedTab = .discover
                    }
                    .padding(.horizontal, PRVSpacing.lg)

                    ScrollView(.horizontal) {
                        HStack(spacing: PRVSpacing.md) {
                            ForEach(salons) { salon in
                                HomeSalonCard(salon: salon) {
                                    open(salon)
                                }
                            }
                        }
                        .padding(.horizontal, PRVSpacing.lg)
                        .padding(.bottom, PRVSpacing.xs)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    /// Records the view for "Recently Viewed" and pushes the salon profile.
    private func open(_ salon: Salon) {
        let salons = deps.salons
        Task { await salons.markViewed(salonID: salon.id) }
        router.push(.salon(salon.id))
    }

    // MARK: - Loyalty

    @ViewBuilder
    private var loyaltySection: some View {
        switch model.loyaltyPhase {
        case .unavailable:
            EmptyView()
        case .loading:
            PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
                HStack(spacing: PRVSpacing.md) {
                    PRVSkeleton(width: 64, height: 64, radius: 32)
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        PRVSkeleton(width: 130, height: 16)
                        PRVSkeleton(width: 170, height: 12)
                    }
                    Spacer()
                }
            }
        case .failed(let message):
            HomeSectionErrorCard(message: message) { reload() }
        case .loaded(let profile):
            LoyaltyBanner(profile: profile) {
                router.push(.loyalty)
            }
        }
    }

    // MARK: - Packages

    @ViewBuilder
    private var packagesSection: some View {
        switch model.packagesPhase {
        case .unavailable:
            EmptyView()
        case .loading:
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader("Offers & Packages")
                    .padding(.horizontal, PRVSpacing.lg)
                RailSkeleton()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader("Offers & Packages")
                    .padding(.horizontal, PRVSpacing.lg)
                HomeSectionErrorCard(message: message) { reload() }
                    .padding(.horizontal, PRVSpacing.lg)
            }
        case .loaded(let packages):
            if packages.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    PRVSectionHeader(
                        "Offers & Packages",
                        subtitle: "Bundles that save you money",
                        actionTitle: "See All"
                    ) {
                        router.push(.packages(salonID: nil))
                    }
                    .padding(.horizontal, PRVSpacing.lg)

                    ScrollView(.horizontal) {
                        HStack(spacing: PRVSpacing.md) {
                            ForEach(packages) { package in
                                PackageCard(package: package) {
                                    router.push(.packages(salonID: package.salonID))
                                }
                            }
                        }
                        .padding(.horizontal, PRVSpacing.lg)
                        .padding(.bottom, PRVSpacing.xs)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    // MARK: - Wallet

    @ViewBuilder
    private var walletSection: some View {
        switch model.walletPhase {
        case .unavailable:
            EmptyView()
        case .loading:
            PRVGlassCard {
                HStack(spacing: PRVSpacing.md) {
                    PRVSkeleton(width: 44, height: 44, radius: 22)
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        PRVSkeleton(width: 110, height: 16)
                        PRVSkeleton(width: 160, height: 12)
                    }
                    Spacer()
                }
            }
        case .failed(let message):
            HomeSectionErrorCard(message: message) { reload() }
        case .loaded(let snapshot):
            WalletSnapshotTile(snapshot: snapshot) {
                router.push(.wallet)
            }
        }
    }

    // MARK: - Actions

    /// Re-runs the full concurrent load (used by inline section retries).
    private func reload() {
        let user = session.currentUser
        let deps = deps
        Task { await model.load(for: user, using: deps) }
    }

    /// MainActor-isolated refresh entry point, callable from the `@Sendable`
    /// pull-to-refresh closure without touching actor-isolated state there.
    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }
}

// MARK: - Previews

#Preview("Home — Client") {
    NavigationStack {
        HomeView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Home — Dark") {
    NavigationStack {
        HomeView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Home — Guest") {
    NavigationStack {
        HomeView()
    }
    .environment(UserSession())
    .environment(AppRouter())
}
