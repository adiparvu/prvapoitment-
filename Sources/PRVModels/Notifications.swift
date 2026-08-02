import Foundation

public struct PRVNotification: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<PRVNotification>

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case appointmentReminder = "appointment_reminder"
        case appointmentConfirmed = "appointment_confirmed"
        case appointmentCancelled = "appointment_cancelled"
        case waitlistSlotOpened = "waitlist_slot_opened"
        case promotion
        case reviewRequest = "review_request"
        case membershipRenewal = "membership_renewal"
        case packageExpiring = "package_expiring"
        case priceChange = "price_change"
        case loyaltyReward = "loyalty_reward"
        case chatMessage = "chat_message"
        case system

        public var symbolName: String {
            switch self {
            case .appointmentReminder: "clock.badge.fill"
            case .appointmentConfirmed: "checkmark.seal.fill"
            case .appointmentCancelled: "xmark.circle.fill"
            case .waitlistSlotOpened: "sparkles"
            case .promotion: "tag.fill"
            case .reviewRequest: "star.bubble.fill"
            case .membershipRenewal: "crown.fill"
            case .packageExpiring: "hourglass"
            case .priceChange: "eurosign.circle.fill"
            case .loyaltyReward: "gift.fill"
            case .chatMessage: "bubble.left.fill"
            case .system: "bell.fill"
            }
        }
    }

    public var id: ID
    public var userID: User.ID
    public var kind: Kind
    public var title: String
    public var body: String
    /// Deep link the notification opens.
    public var route: AppRoute?
    public var isRead: Bool
    public var createdAt: Date

    public init(
        id: ID = ID(),
        userID: User.ID,
        kind: Kind,
        title: String,
        body: String,
        route: AppRoute? = nil,
        isRead: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.kind = kind
        self.title = title
        self.body = body
        self.route = route
        self.isRead = isRead
        self.createdAt = createdAt
    }
}
