import SwiftUI
import PRVDesignSystem
import PRVModels
import PRVNetworking
import PRVAuthFeature
import PRVHomeFeature
import PRVDiscoverFeature
import PRVSalonProfileFeature
import PRVBookingFeature
import PRVPaymentsFeature
import PRVWalletFeature
import PRVMembershipsFeature
import PRVChatFeature
import PRVNotificationsFeature
import PRVDashboardFeature
import PRVCRMFeature
import PRVOperationsFeature

/// Role-aware root: authentication gate, then the client or business
/// experience with a floating Liquid Glass tab bar.
struct RootView: View {
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    let hasRestoredSession: Bool

    /// Set when a visitor chooses "Continue as Guest": the auth surface steps
    /// aside and the browse-only client experience takes over until they sign
    /// in. Signing in or out re-arms the gate.
    @State private var isBrowsingAsGuest = false

    var body: some View {
        Group {
            if !hasRestoredSession {
                LaunchView()
            } else if session.isBusinessExperience {
                BusinessExperienceView()
            } else {
                // The client experience hosts the gate as a cover so
                // `AuthRootView`'s `dismiss()` — how it hands control back
                // after the guest sheet — resolves to a real presentation and
                // reveals the browse-only experience underneath.
                ClientExperienceView(endGuestBrowsing: guestEscape)
                    .fullScreenCover(isPresented: isPresentingAuth) {
                        AuthRootView()
                    }
            }
        }
        .animation(PRVMotion.gentle, value: session.isAuthenticated)
        .animation(PRVMotion.gentle, value: session.isBusinessExperience)
        .onChange(of: session.isAuthenticated) { _, _ in
            isBrowsingAsGuest = false
        }
        .onChange(of: session.isBusinessExperience, initial: true) { _, isBusiness in
            normalizeSelectedTab(isBusinessExperience: isBusiness)
        }
    }

    /// Presents the welcome surface until the visitor either signs in or
    /// explicitly chooses to browse as a guest. Dismissal is the guest path,
    /// so it records the choice instead of re-presenting immediately.
    private var isPresentingAuth: Binding<Bool> {
        Binding(
            get: { hasRestoredSession && !session.isAuthenticated && !isBrowsingAsGuest },
            set: { isPresented in
                guard !isPresented else { return }
                isBrowsingAsGuest = true
            }
        )
    }

    /// The way back to the welcome screen while browsing as a guest; `nil`
    /// for signed-in clients, who reach sign-out through Settings instead.
    private var guestEscape: (() -> Void)? {
        guard isBrowsingAsGuest else { return nil }
        return { isBrowsingAsGuest = false }
    }

    /// Keeps `AppRouter.selectedTab` inside the tab set the active experience
    /// renders. The router defaults to `.home`, which is absent from
    /// `AppTab.businessTabs`, so a salon user would otherwise land on a
    /// selection that matches no `Tab` — and push routes onto a navigation
    /// path nothing builds.
    private func normalizeSelectedTab(isBusinessExperience: Bool) {
        let tabs = isBusinessExperience ? AppTab.businessTabs : AppTab.clientTabs
        guard !tabs.contains(router.selectedTab) else { return }
        router.selectedTab = isBusinessExperience ? .dashboard : .home
    }
}

/// Minimal splash shown only while the persisted session restores (<1s).
private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.prv.canvas.ignoresSafeArea()
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.prv.accentGradient)
        }
    }
}

// MARK: - Client experience

private struct ClientExperienceView: View {
    @Environment(AppRouter.self) private var router

    /// Non-`nil` while the visitor is browsing without an account. Guests get
    /// the shell's own "Sign In" affordance, which brings the welcome screen
    /// back — the feature-level guest states only explain what stays locked.
    let endGuestBrowsing: (() -> Void)?

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.clientTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.symbolName, value: tab, role: role(for: tab)) {
                    NavigationStack(path: pathBinding(for: tab)) {
                        clientRoot(for: tab)
                            .navigationDestination(for: AppRoute.self) { route in
                                RouteDestinationView(route: route)
                            }
                            .toolbar { guestToolbarContent }
                    }
                }
                // No `.accessibilityIdentifier` here: that modifier is declared
                // on `View`, and `Tab` is `TabContent`. The UI suite selects
                // tabs by their title, which is how XCUITest addresses a tab bar
                // regardless.
            }
        }
        .sheet(item: sheetBinding) { route in
            NavigationStack {
                RouteDestinationView(route: route.route)
            }
        }
    }

    /// Discover carries the client tab bar's conversion path: finding a salon
    /// is where every booking, payment, and loyalty award starts, and it is the
    /// only tab a guest can act on without an account. It therefore takes the
    /// featured `.prominent` placement; Home, Bookings, Chat, and Wallet are
    /// peers that manage what Discover produced, so they stay unroled.
    private func role(for tab: AppTab) -> TabRole? {
        tab == .discover ? .prominent : nil
    }

    /// Sign In is pinned rather than merely trailing: this toolbar is merged
    /// into whatever the feature root already contributes, and it is a guest's
    /// only route back to the welcome screen. Pinning keeps it on the bar
    /// instead of letting it collapse behind a feature's own items.
    @ToolbarContentBuilder
    private var guestToolbarContent: some ToolbarContent {
        if let endGuestBrowsing {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                Button("Sign In") {
                    PRVHaptics.tap()
                    endGuestBrowsing()
                }
                .accessibilityHint("Returns to the welcome screen to sign in or create an account.")
                .accessibilityIdentifier("shell.signIn")
            }
        }
    }

    /// Every client feature root in one switch — the app's heaviest
    /// type-check site, so it is built with `@ContentBuilder`.
    @ContentBuilder
    private func clientRoot(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .appointments: AppointmentsListView()
        case .chat: ChatListView()
        case .wallet: WalletView()
        default: HomeView()
        }
    }

    /// Reads through a clamp so the selection always matches a rendered `Tab`,
    /// even for a value left behind by the business experience.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { AppTab.clientTabs.contains(router.selectedTab) ? router.selectedTab : .home },
            set: { router.selectedTab = $0 }
        )
    }

    private func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(
            get: { router.paths[tab] ?? [] },
            set: { router.paths[tab] = $0 }
        )
    }

    private var sheetBinding: Binding<PresentedRoute?> {
        Binding(
            get: { router.presentedSheet.map(PresentedRoute.init) },
            set: { router.presentedSheet = $0?.route }
        )
    }
}

// MARK: - Business experience

private struct BusinessExperienceView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.businessTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.symbolName, value: tab) {
                    NavigationStack(path: pathBinding(for: tab)) {
                        businessRoot(for: tab)
                            .navigationDestination(for: AppRoute.self) { route in
                                RouteDestinationView(route: route)
                            }
                    }
                }
                // See the client tab bar: `Tab` is `TabContent`, not `View`.
            }
        }
        .sheet(item: sheetBinding) { route in
            NavigationStack {
                RouteDestinationView(route: route.route)
            }
        }
    }

    /// Every business feature root in one switch — like its client
    /// counterpart, built with `@ContentBuilder` to keep the shell's
    /// type-check cost down.
    @ContentBuilder
    private func businessRoot(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard: SalonDashboardView()
        // The salon's own day book — `AppointmentsListView` is client-scoped
        // and would show the signed-in owner's personal bookings here.
        case .calendar: SalonScheduleView()
        case .clients: CRMView()
        case .chat: ChatListView()
        case .operations: TeamView()
        default: SalonDashboardView()
        }
    }

    /// Reads through a clamp so the selection always matches a rendered `Tab`,
    /// even before the router has been normalized for this experience.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { AppTab.businessTabs.contains(router.selectedTab) ? router.selectedTab : .dashboard },
            set: { router.selectedTab = $0 }
        )
    }

    private func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(
            get: { router.paths[tab] ?? [] },
            set: { router.paths[tab] = $0 }
        )
    }

    private var sheetBinding: Binding<PresentedRoute?> {
        Binding(
            get: { router.presentedSheet.map(PresentedRoute.init) },
            set: { router.presentedSheet = $0?.route }
        )
    }
}

// MARK: - Route mapping

private struct PresentedRoute: Identifiable {
    let route: AppRoute
    var id: AppRoute { route }
}

/// Maps every `AppRoute` to its owning feature's view. This is the only
/// place in the app that knows about all features at once.
struct RouteDestinationView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .salon(let id):
            SalonProfileView(salonID: id)
        case .professional(let id):
            ProfessionalProfileView(professionalID: id)
        case .service(let serviceID, let salonID):
            SalonProfileView(salonID: salonID, linkedServiceID: serviceID)
        case .booking(let salonID, let serviceIDs):
            BookingFlowView(context: BookingContext(salonID: salonID, serviceIDs: serviceIDs))
        case .appointment(let id):
            AppointmentDetailView(appointmentID: id)
        case .checkout(let orderID):
            CheckoutView(order: orderID)
        case .conversation(let id):
            ConversationView(conversationID: id)
        case .beautyAssistant:
            BeautyAssistantView()
        case .wallet:
            WalletView()
        case .loyalty:
            LoyaltyView()
        case .memberships(let salonID):
            MembershipsView(salonID: salonID)
        case .packages(let salonID):
            PackagesView(salonID: salonID)
        case .giftCards:
            GiftCardsView()
        case .notifications:
            NotificationCenterView()
        case .reviews(let salonID):
            SalonProfileView(salonID: salonID, section: .reviews)
        case .clientRecord(let id):
            ClientDetailView(clientID: id)
        case .settings:
            SettingsPlaceholderView()
        }
    }
}

/// Settings lives in the app target until it grows into its own module.
struct SettingsPlaceholderView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    @State private var isSigningOut = false

    var body: some View {
        List {
            if let user = session.currentUser {
                Section {
                    HStack(spacing: PRVSpacing.md) {
                        Circle()
                            .fill(Color.prv.accentGradient)
                            .frame(width: 52, height: 52)
                            .overlay {
                                Text(user.initials)
                                    .font(.headline)
                                    .foregroundStyle(Color.prv.textOnAccent)
                            }
                        VStack(alignment: .leading) {
                            Text(user.fullName).prvStyle(.headline)
                            Text(user.role.displayName).prvStyle(.footnote)
                        }
                    }
                }
            }
            Section {
                Button("Sign Out", role: .destructive) {
                    signOut()
                }
                .disabled(isSigningOut)
            }
        }
        .navigationTitle("Settings")
    }

    /// Ends the session on the backend first — that is what drops the
    /// persisted, Keychain-backed token — then clears the in-memory session so
    /// the shell returns to the welcome screen.
    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await deps.auth.signOut()
            session.signedOut()
            isSigningOut = false
        }
    }
}
