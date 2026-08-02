import Foundation

/// Every role in the PRV Beauty ecosystem.
public enum UserRole: String, Codable, Hashable, Sendable, CaseIterable {
    case guest
    case client
    case premiumClient = "premium_client"
    case freelancer
    case salonEmployee = "salon_employee"
    case salonManager = "salon_manager"
    case salonOwner = "salon_owner"
    case multiSalonOwner = "multi_salon_owner"
    case regionalManager = "regional_manager"
    case support
    case finance
    case marketing
    case administrator
    case superAdmin = "super_admin"
    case developer

    public var displayName: String {
        switch self {
        case .guest: "Guest"
        case .client: "Client"
        case .premiumClient: "Premium Client"
        case .freelancer: "Freelancer"
        case .salonEmployee: "Salon Employee"
        case .salonManager: "Salon Manager"
        case .salonOwner: "Salon Owner"
        case .multiSalonOwner: "Multi-Salon Owner"
        case .regionalManager: "Regional Manager"
        case .support: "Support"
        case .finance: "Finance"
        case .marketing: "Marketing"
        case .administrator: "Administrator"
        case .superAdmin: "Super Admin"
        case .developer: "Developer"
        }
    }

    /// Whether this role primarily uses the business side of the app.
    public var isBusinessRole: Bool {
        switch self {
        case .guest, .client, .premiumClient: false
        default: true
        }
    }

    public var permissions: Set<Permission> {
        switch self {
        case .guest:
            [.browse]
        case .client:
            [.browse, .book, .review, .chat, .payOnline]
        case .premiumClient:
            UserRole.client.permissions.union([.priorityBooking])
        case .freelancer:
            [.browse, .chat, .manageOwnCalendar, .manageOwnServices, .viewOwnEarnings]
        case .salonEmployee:
            [.browse, .chat, .manageOwnCalendar, .viewClients, .checkInOut]
        case .salonManager:
            UserRole.salonEmployee.permissions.union([
                .manageCalendar, .manageTeam, .manageInventory, .viewReports,
                .manageServices, .respondToReviews, .manageCRM,
            ])
        case .salonOwner:
            UserRole.salonManager.permissions.union([
                .manageSalon, .managePayroll, .manageMarketing, .manageMemberships,
                .manageFinance, .configurePrepayment,
            ])
        case .multiSalonOwner, .regionalManager:
            UserRole.salonOwner.permissions.union([.manageMultipleLocations, .compareLocations])
        case .support:
            [.browse, .viewClients, .manageRefunds, .chat, .moderateReviews]
        case .finance:
            [.viewReports, .manageFinance, .manageRefunds, .managePayroll]
        case .marketing:
            [.viewReports, .manageMarketing]
        case .administrator:
            Set(Permission.allCases).subtracting([.developerTools])
        case .superAdmin, .developer:
            Set(Permission.allCases)
        }
    }
}

public enum Permission: String, Codable, Hashable, Sendable, CaseIterable {
    case browse
    case book
    case review
    case chat
    case payOnline
    case priorityBooking
    case manageOwnCalendar
    case manageOwnServices
    case viewOwnEarnings
    case viewClients
    case checkInOut
    case manageCalendar
    case manageTeam
    case manageInventory
    case viewReports
    case manageServices
    case respondToReviews
    case manageCRM
    case manageSalon
    case managePayroll
    case manageMarketing
    case manageMemberships
    case manageFinance
    case configurePrepayment
    case manageMultipleLocations
    case compareLocations
    case manageRefunds
    case moderateReviews
    case manageFeatureFlags
    case developerTools
}

/// A platform account. Profile data specific to clients/professionals lives in
/// `ClientRecord` / `Professional`.
public struct User: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<User>

    public var id: ID
    public var role: UserRole
    public var firstName: String
    public var lastName: String
    public var email: String
    public var phone: String?
    public var avatarURL: URL?
    public var preferredLanguage: String
    public var createdAt: Date
    /// Salons this user belongs to (staff/owners); empty for clients.
    public var salonIDs: [PRVID<Salon>]

    public init(
        id: ID = ID(),
        role: UserRole,
        firstName: String,
        lastName: String,
        email: String,
        phone: String? = nil,
        avatarURL: URL? = nil,
        preferredLanguage: String = "en",
        createdAt: Date = .now,
        salonIDs: [PRVID<Salon>] = []
    ) {
        self.id = id
        self.role = role
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.avatarURL = avatarURL
        self.preferredLanguage = preferredLanguage
        self.createdAt = createdAt
        self.salonIDs = salonIDs
    }

    public var fullName: String { "\(firstName) \(lastName)" }

    public var initials: String {
        [firstName.first, lastName.first].compactMap { $0.map(String.init) }.joined()
    }

    public func can(_ permission: Permission) -> Bool {
        role.permissions.contains(permission)
    }
}
