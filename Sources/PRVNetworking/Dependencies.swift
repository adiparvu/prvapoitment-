import Foundation
import Observation
import SwiftUI
import PRVModels

/// Aggregates every data dependency. Injected once at the app root:
///
///     RootView()
///         .environment(\.prvDependencies, .live())
///
/// Features resolve repositories with `@Environment(\.prvDependencies)`.
public struct PRVDependencies: Sendable {
    public var auth: any AuthService
    public var salons: any SalonRepository
    public var appointments: any AppointmentRepository
    public var payments: any PaymentRepository
    public var memberships: any MembershipRepository
    public var loyalty: any LoyaltyRepository
    public var chat: any ChatRepository
    public var notifications: any NotificationRepository
    public var crm: any CRMRepository
    public var team: any TeamRepository
    public var inventory: any InventoryRepository
    public var marketing: any MarketingRepository
    public var analytics: any AnalyticsRepository

    public init(
        auth: any AuthService,
        salons: any SalonRepository,
        appointments: any AppointmentRepository,
        payments: any PaymentRepository,
        memberships: any MembershipRepository,
        loyalty: any LoyaltyRepository,
        chat: any ChatRepository,
        notifications: any NotificationRepository,
        crm: any CRMRepository,
        team: any TeamRepository,
        inventory: any InventoryRepository,
        marketing: any MarketingRepository,
        analytics: any AnalyticsRepository
    ) {
        self.auth = auth
        self.salons = salons
        self.appointments = appointments
        self.payments = payments
        self.memberships = memberships
        self.loyalty = loyalty
        self.chat = chat
        self.notifications = notifications
        self.crm = crm
        self.team = team
        self.inventory = inventory
        self.marketing = marketing
        self.analytics = analytics
    }

    /// One shared in-memory backend for previews, demo mode, and tests.
    public static func inMemory(_ backend: InMemoryBackend = InMemoryBackend()) -> PRVDependencies {
        PRVDependencies(
            auth: backend,
            salons: backend,
            appointments: backend,
            payments: backend,
            memberships: backend,
            loyalty: backend,
            chat: backend,
            notifications: backend,
            crm: backend,
            team: backend,
            inventory: backend,
            marketing: backend,
            analytics: backend
        )
    }
}

extension EnvironmentValues {
    /// Defaults to the in-memory backend so previews work with zero setup.
    @Entry public var prvDependencies: PRVDependencies = .inMemory()
}

// MARK: - Session

/// Observable authentication/session state, injected at the app root with
/// `.environment(session)` and read via `@Environment(UserSession.self)`.
@Observable
@MainActor
public final class UserSession {
    public private(set) var currentUser: User?
    /// The salon a business user is currently operating (multi-salon switching).
    public var activeSalonID: Salon.ID?
    /// Whether a business-capable user is currently in the client experience.
    public var isViewingAsClient = false

    public init(currentUser: User? = nil) {
        self.currentUser = currentUser
        self.activeSalonID = currentUser?.salonIDs.first
    }

    public var isAuthenticated: Bool { currentUser != nil }

    public var isBusinessExperience: Bool {
        guard let user = currentUser else { return false }
        return user.role.isBusinessRole && !isViewingAsClient
    }

    public func can(_ permission: Permission) -> Bool {
        currentUser?.can(permission) ?? false
    }

    public func signedIn(_ user: User) {
        currentUser = user
        activeSalonID = user.salonIDs.first
        isViewingAsClient = false
    }

    public func signedOut() {
        currentUser = nil
        activeSalonID = nil
        isViewingAsClient = false
    }

    /// Preview session for a premium client.
    public static var previewClient: UserSession {
        UserSession(currentUser: PreviewData.client)
    }

    /// Preview session for a salon owner.
    public static var previewOwner: UserSession {
        UserSession(currentUser: PreviewData.owner)
    }
}
