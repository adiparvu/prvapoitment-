import Foundation

/// A salon's complete record of one client (CRM).
public struct ClientRecord: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ClientRecord>

    public var id: ID
    public var salonID: Salon.ID
    public var userID: User.ID?
    public var firstName: String
    public var lastName: String
    public var email: String?
    public var phone: String?
    public var avatarURL: URL?
    public var birthday: Date?
    public var skinType: String?
    public var hairType: String?
    public var allergies: [String]
    public var preferences: [String]
    public var favoriteProductIDs: [Product.ID]
    public var totalVisits: Int
    public var totalSpend: Money
    public var lastVisitAt: Date?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        userID: User.ID? = nil,
        firstName: String,
        lastName: String,
        email: String? = nil,
        phone: String? = nil,
        avatarURL: URL? = nil,
        birthday: Date? = nil,
        skinType: String? = nil,
        hairType: String? = nil,
        allergies: [String] = [],
        preferences: [String] = [],
        favoriteProductIDs: [Product.ID] = [],
        totalVisits: Int = 0,
        totalSpend: Money = .zero(),
        lastVisitAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.salonID = salonID
        self.userID = userID
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.avatarURL = avatarURL
        self.birthday = birthday
        self.skinType = skinType
        self.hairType = hairType
        self.allergies = allergies
        self.preferences = preferences
        self.favoriteProductIDs = favoriteProductIDs
        self.totalVisits = totalVisits
        self.totalSpend = totalSpend
        self.lastVisitAt = lastVisitAt
        self.createdAt = createdAt
    }

    public var fullName: String { "\(firstName) \(lastName)" }
}

public struct ClientNote: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ClientNote>

    public enum Kind: String, Codable, Hashable, Sendable {
        case general
        case colorFormula = "color_formula"
        case treatment
        case photo
    }

    public var id: ID
    public var clientRecordID: ClientRecord.ID
    public var authorID: User.ID
    public var kind: Kind
    public var text: String
    public var photoURLs: [URL]
    public var appointmentID: Appointment.ID?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        clientRecordID: ClientRecord.ID,
        authorID: User.ID,
        kind: Kind = .general,
        text: String,
        photoURLs: [URL] = [],
        appointmentID: Appointment.ID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.clientRecordID = clientRecordID
        self.authorID = authorID
        self.kind = kind
        self.text = text
        self.photoURLs = photoURLs
        self.appointmentID = appointmentID
        self.createdAt = createdAt
    }
}

/// A versioned consent form signature (GDPR / treatment consent).
public struct ConsentForm: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ConsentForm>

    public var id: ID
    public var clientRecordID: ClientRecord.ID
    public var title: String
    public var version: String
    public var documentURL: URL?
    public var signedAt: Date?

    public init(
        id: ID = ID(),
        clientRecordID: ClientRecord.ID,
        title: String,
        version: String,
        documentURL: URL? = nil,
        signedAt: Date? = nil
    ) {
        self.id = id
        self.clientRecordID = clientRecordID
        self.title = title
        self.version = version
        self.documentURL = documentURL
        self.signedAt = signedAt
    }
}
