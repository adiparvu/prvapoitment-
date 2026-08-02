import Foundation

public struct Conversation: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Conversation>

    public enum Kind: String, Codable, Hashable, Sendable {
        case clientSalon = "client_salon"
        case clientProfessional = "client_professional"
        case assistant
        case support
    }

    public var id: ID
    public var kind: Kind
    public var title: String
    public var avatarURL: URL?
    public var participantIDs: [User.ID]
    public var salonID: Salon.ID?
    public var lastMessagePreview: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int
    /// True when transport-level end-to-end encryption is active.
    public var isEncrypted: Bool

    public init(
        id: ID = ID(),
        kind: Kind,
        title: String,
        avatarURL: URL? = nil,
        participantIDs: [User.ID] = [],
        salonID: Salon.ID? = nil,
        lastMessagePreview: String? = nil,
        lastMessageAt: Date? = nil,
        unreadCount: Int = 0,
        isEncrypted: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.avatarURL = avatarURL
        self.participantIDs = participantIDs
        self.salonID = salonID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.isEncrypted = isEncrypted
    }
}

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ChatMessage>

    public enum Content: Codable, Hashable, Sendable {
        case text(String)
        case photo(URL, caption: String?)
        case video(URL, caption: String?)
        case voice(URL, durationSeconds: Int)
        /// A structured appointment request the recipient can accept.
        case appointmentRequest(serviceID: SalonService.ID, preferredDate: Date)
        /// Assistant recommendation payload.
        case recommendation(AssistantRecommendation)
    }

    public enum DeliveryState: String, Codable, Hashable, Sendable {
        case sending
        case sent
        case delivered
        case read
        case failed
    }

    public var id: ID
    public var conversationID: Conversation.ID
    public var senderID: User.ID?
    /// True for messages authored by the AI assistant.
    public var isFromAssistant: Bool
    public var content: Content
    public var deliveryState: DeliveryState
    public var sentAt: Date

    public init(
        id: ID = ID(),
        conversationID: Conversation.ID,
        senderID: User.ID? = nil,
        isFromAssistant: Bool = false,
        content: Content,
        deliveryState: DeliveryState = .sent,
        sentAt: Date = .now
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.isFromAssistant = isFromAssistant
        self.content = content
        self.deliveryState = deliveryState
        self.sentAt = sentAt
    }
}

/// What the AI Beauty Assistant recommends in response to a client goal.
public struct AssistantRecommendation: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<AssistantRecommendation>

    public var id: ID
    public var headline: String
    public var rationale: String
    public var serviceIDs: [SalonService.ID]
    public var salonIDs: [Salon.ID]
    public var professionalIDs: [Professional.ID]
    public var packageIDs: [ServicePackage.ID]
    public var suggestedSlots: [TimeSlot]
    /// e.g. "Refresh every 6 weeks" maintenance plan.
    public var maintenanceAdvice: String?

    public init(
        id: ID = ID(),
        headline: String,
        rationale: String,
        serviceIDs: [SalonService.ID] = [],
        salonIDs: [Salon.ID] = [],
        professionalIDs: [Professional.ID] = [],
        packageIDs: [ServicePackage.ID] = [],
        suggestedSlots: [TimeSlot] = [],
        maintenanceAdvice: String? = nil
    ) {
        self.id = id
        self.headline = headline
        self.rationale = rationale
        self.serviceIDs = serviceIDs
        self.salonIDs = salonIDs
        self.professionalIDs = professionalIDs
        self.packageIDs = packageIDs
        self.suggestedSlots = suggestedSlots
        self.maintenanceAdvice = maintenanceAdvice
    }
}
