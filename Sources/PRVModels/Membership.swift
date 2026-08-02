import Foundation

public enum MembershipTier: String, Codable, Hashable, Sendable, CaseIterable {
    case silver
    case gold
    case diamond
    case black
    case custom

    public var displayName: String {
        switch self {
        case .silver: "Silver"
        case .gold: "Gold"
        case .diamond: "Diamond"
        case .black: "Black"
        case .custom: "Custom"
        }
    }
}

public enum BillingCycle: String, Codable, Hashable, Sendable, CaseIterable {
    case monthly
    case quarterly
    case yearly

    public var displayName: String {
        switch self {
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        }
    }

    public var months: Int {
        switch self {
        case .monthly: 1
        case .quarterly: 3
        case .yearly: 12
        }
    }
}

public struct MembershipBenefit: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<MembershipBenefit>

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case freeService = "free_service"
        case discountPercent = "discount_percent"
        case priorityBooking = "priority_booking"
        case birthdayGift = "birthday_gift"
        case exclusiveEvents = "exclusive_events"
        case partnerBenefit = "partner_benefit"
    }

    public var id: ID
    public var kind: Kind
    public var title: String
    /// e.g. discount percent, or number of free services per cycle.
    public var value: Int?
    public var serviceID: SalonService.ID?

    public init(id: ID = ID(), kind: Kind, title: String, value: Int? = nil, serviceID: SalonService.ID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.value = value
        self.serviceID = serviceID
    }
}

/// A membership plan a salon sells (e.g. "Gold — monthly").
public struct MembershipPlan: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<MembershipPlan>

    public var id: ID
    public var salonID: Salon.ID
    public var tier: MembershipTier
    public var name: String
    public var details: String
    public var price: Money
    public var cycle: BillingCycle
    public var benefits: [MembershipBenefit]
    public var isActive: Bool

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        tier: MembershipTier,
        name: String,
        details: String = "",
        price: Money,
        cycle: BillingCycle,
        benefits: [MembershipBenefit] = [],
        isActive: Bool = true
    ) {
        self.id = id
        self.salonID = salonID
        self.tier = tier
        self.name = name
        self.details = details
        self.price = price
        self.cycle = cycle
        self.benefits = benefits
        self.isActive = isActive
    }
}

/// A client's active subscription to a membership plan.
public struct MembershipSubscription: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<MembershipSubscription>

    public enum Status: String, Codable, Hashable, Sendable {
        case active
        case pastDue = "past_due"
        case cancelled
        case expired
    }

    public var id: ID
    public var planID: MembershipPlan.ID
    public var plan: MembershipPlan?
    public var userID: User.ID
    public var status: Status
    public var startedAt: Date
    public var renewsAt: Date
    public var cancelledAt: Date?

    public init(
        id: ID = ID(),
        planID: MembershipPlan.ID,
        plan: MembershipPlan? = nil,
        userID: User.ID,
        status: Status = .active,
        startedAt: Date = .now,
        renewsAt: Date,
        cancelledAt: Date? = nil
    ) {
        self.id = id
        self.planID = planID
        self.plan = plan
        self.userID = userID
        self.status = status
        self.startedAt = startedAt
        self.renewsAt = renewsAt
        self.cancelledAt = cancelledAt
    }
}

/// A bundle of services sold at a package price (Wedding, Luxury Spa, …).
public struct ServicePackage: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ServicePackage>

    public enum Theme: String, Codable, Hashable, Sendable, CaseIterable {
        case wedding
        case holiday
        case seasonal
        case monthly
        case luxurySpa = "luxury_spa"
        case combo
        case custom
    }

    public var id: ID
    public var salonID: Salon.ID
    public var name: String
    public var details: String
    public var theme: Theme
    public var serviceIDs: [SalonService.ID]
    public var regularPrice: Money
    public var packagePrice: Money
    public var imageURL: URL?
    /// Days the purchaser has to redeem all included services.
    public var validityDays: Int
    public var isActive: Bool

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        name: String,
        details: String = "",
        theme: Theme,
        serviceIDs: [SalonService.ID],
        regularPrice: Money,
        packagePrice: Money,
        imageURL: URL? = nil,
        validityDays: Int = 365,
        isActive: Bool = true
    ) {
        self.id = id
        self.salonID = salonID
        self.name = name
        self.details = details
        self.theme = theme
        self.serviceIDs = serviceIDs
        self.regularPrice = regularPrice
        self.packagePrice = packagePrice
        self.imageURL = imageURL
        self.validityDays = validityDays
        self.isActive = isActive
    }

    public var savings: Money { regularPrice - packagePrice }
}
