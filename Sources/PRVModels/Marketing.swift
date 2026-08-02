import Foundation

public struct Campaign: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Campaign>

    public enum Channel: String, Codable, Hashable, Sendable, CaseIterable {
        case push
        case email
        case sms

        public var displayName: String {
            switch self {
            case .push: "Push"
            case .email: "Email"
            case .sms: "SMS"
            }
        }
    }

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case promotion
        case referral
        case birthday
        case winBack = "win_back"
        case newService = "new_service"
        case automatic
    }

    public enum Status: String, Codable, Hashable, Sendable {
        case draft
        case scheduled
        case running
        case completed
        case paused
    }

    public var id: ID
    public var salonID: Salon.ID
    public var name: String
    public var kind: Kind
    public var channels: [Channel]
    public var message: String
    public var couponID: Coupon.ID?
    public var status: Status
    public var scheduledAt: Date?
    public var sentCount: Int
    public var openCount: Int
    public var bookingCount: Int
    public var attributedRevenue: Money

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        name: String,
        kind: Kind,
        channels: [Channel],
        message: String,
        couponID: Coupon.ID? = nil,
        status: Status = .draft,
        scheduledAt: Date? = nil,
        sentCount: Int = 0,
        openCount: Int = 0,
        bookingCount: Int = 0,
        attributedRevenue: Money = .zero()
    ) {
        self.id = id
        self.salonID = salonID
        self.name = name
        self.kind = kind
        self.channels = channels
        self.message = message
        self.couponID = couponID
        self.status = status
        self.scheduledAt = scheduledAt
        self.sentCount = sentCount
        self.openCount = openCount
        self.bookingCount = bookingCount
        self.attributedRevenue = attributedRevenue
    }
}

public struct Coupon: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Coupon>

    public enum Discount: Codable, Hashable, Sendable {
        case percent(Int)
        case fixed(Money)
    }

    public var id: ID
    public var salonID: Salon.ID
    public var code: String
    public var discount: Discount
    public var maxRedemptions: Int?
    public var redemptionCount: Int
    public var minimumSpend: Money?
    public var validFrom: Date
    public var validUntil: Date?
    public var isActive: Bool

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        code: String,
        discount: Discount,
        maxRedemptions: Int? = nil,
        redemptionCount: Int = 0,
        minimumSpend: Money? = nil,
        validFrom: Date = .now,
        validUntil: Date? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.salonID = salonID
        self.code = code
        self.discount = discount
        self.maxRedemptions = maxRedemptions
        self.redemptionCount = redemptionCount
        self.minimumSpend = minimumSpend
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.isActive = isActive
    }
}
