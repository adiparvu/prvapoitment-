import Foundation
import Observation

/// The app's top-level tabs. Which set is shown depends on the session role.
public enum AppTab: String, Hashable, Sendable, CaseIterable {
    // Client side
    case home
    case discover
    case appointments
    case chat
    case wallet
    // Business side
    case dashboard
    case calendar
    case clients
    case operations

    public var title: String {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .appointments: "Bookings"
        case .chat: "Chat"
        case .wallet: "Wallet"
        case .dashboard: "Dashboard"
        case .calendar: "Calendar"
        case .clients: "Clients"
        case .operations: "Studio"
        }
    }

    public var symbolName: String {
        switch self {
        case .home: "house.fill"
        case .discover: "sparkle.magnifyingglass"
        case .appointments: "calendar"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .wallet: "wallet.pass.fill"
        case .dashboard: "chart.bar.fill"
        case .calendar: "calendar.badge.clock"
        case .clients: "person.2.fill"
        case .operations: "building.2.fill"
        }
    }

    public static var clientTabs: [AppTab] { [.home, .discover, .appointments, .chat, .wallet] }
    public static var businessTabs: [AppTab] { [.dashboard, .calendar, .clients, .chat, .operations] }
}

/// Every navigable destination in the app. Features push routes onto the
/// shared `AppRouter` instead of importing each other.
public enum AppRoute: Codable, Hashable, Sendable {
    case salon(Salon.ID)
    case professional(Professional.ID)
    case service(SalonService.ID, salonID: Salon.ID)
    case booking(salonID: Salon.ID, serviceIDs: [SalonService.ID])
    case appointment(Appointment.ID)
    case checkout(Order.ID)
    case conversation(Conversation.ID)
    case beautyAssistant
    case wallet
    case loyalty
    case memberships(salonID: Salon.ID?)
    case packages(salonID: Salon.ID?)
    case giftCards
    case notifications
    case reviews(salonID: Salon.ID)
    case clientRecord(ClientRecord.ID)
    case settings
}

/// Observable navigation state shared across features. One router per role
/// experience; each tab owns an independent path.
@Observable
@MainActor
public final class AppRouter {
    public var selectedTab: AppTab
    public var paths: [AppTab: [AppRoute]]
    /// Route presented modally over everything (checkout, assistant, …).
    public var presentedSheet: AppRoute?

    public init(selectedTab: AppTab = .home) {
        self.selectedTab = selectedTab
        self.paths = [:]
    }

    public var currentPath: [AppRoute] {
        get { paths[selectedTab] ?? [] }
        set { paths[selectedTab] = newValue }
    }

    public func push(_ route: AppRoute) {
        paths[selectedTab, default: []].append(route)
    }

    public func pop() {
        guard !(paths[selectedTab]?.isEmpty ?? true) else { return }
        paths[selectedTab]?.removeLast()
    }

    public func popToRoot() {
        paths[selectedTab] = []
    }

    public func present(_ route: AppRoute) {
        presentedSheet = route
    }

    /// Handles a deep link or notification route from anywhere in the app.
    public func open(_ route: AppRoute, in tab: AppTab? = nil) {
        if let tab { selectedTab = tab }
        push(route)
    }
}
