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

    let hasRestoredSession: Bool

    var body: some View {
        Group {
            if !hasRestoredSession {
                LaunchView()
            } else if !session.isAuthenticated {
                AuthRootView()
            } else if session.isBusinessExperience {
                BusinessExperienceView()
            } else {
                ClientExperienceView()
            }
        }
        .animation(PRVMotion.gentle, value: session.isAuthenticated)
        .animation(PRVMotion.gentle, value: session.isBusinessExperience)
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

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.clientTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.symbolName, value: tab) {
                    NavigationStack(path: pathBinding(for: tab)) {
                        clientRoot(for: tab)
                            .navigationDestination(for: AppRoute.self) { route in
                                RouteDestinationView(route: route)
                            }
                    }
                }
            }
        }
        .sheet(item: sheetBinding) { route in
            NavigationStack {
                RouteDestinationView(route: route.route)
            }
        }
    }

    @ViewBuilder
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
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.businessTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.symbolName, value: tab) {
                    NavigationStack(path: pathBinding(for: tab)) {
                        businessRoot(for: tab)
                            .navigationDestination(for: AppRoute.self) { route in
                                RouteDestinationView(route: route)
                            }
                    }
                }
            }
        }
        .sheet(item: sheetBinding) { route in
            NavigationStack {
                RouteDestinationView(route: route.route)
            }
        }
    }

    @ViewBuilder
    private func businessRoot(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard: SalonDashboardView()
        case .calendar: AppointmentsListView()
        case .clients: CRMView()
        case .chat: ChatListView()
        case .operations: TeamView()
        default: SalonDashboardView()
        }
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
        case .service(_, let salonID):
            SalonProfileView(salonID: salonID)
        case .booking(let salonID, let serviceIDs):
            BookingFlowView(context: BookingContext(salonID: salonID, serviceIDs: serviceIDs))
        case .appointment:
            AppointmentsListView()
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
            SalonProfileView(salonID: salonID)
        case .clientRecord(let id):
            ClientDetailView(clientID: id)
        case .settings:
            SettingsPlaceholderView()
        }
    }
}

/// Settings lives in the app target until it grows into its own module.
struct SettingsPlaceholderView: View {
    @Environment(UserSession.self) private var session

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
                    session.signedOut()
                }
            }
        }
        .navigationTitle("Settings")
    }
}
