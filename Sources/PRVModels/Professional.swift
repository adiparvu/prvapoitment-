import Foundation

/// A beauty professional — salon staff member or independent freelancer.
public struct Professional: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Professional>

    public var id: ID
    /// Platform account backing this professional, when they have one.
    public var userID: User.ID?
    public var salonID: Salon.ID?
    public var displayName: String
    public var title: String
    public var biography: String
    public var photoURL: URL?
    public var yearsOfExperience: Int
    public var specialties: [String]
    public var languages: [String]
    public var certificates: [Certificate]
    public var portfolio: [PortfolioItem]
    public var instagramHandle: String?
    public var tikTokHandle: String?
    public var rating: Double
    public var reviewCount: Int
    /// Typical time to answer a chat message, in minutes.
    public var averageResponseMinutes: Int?
    public var isFreelancer: Bool
    /// Services this professional performs.
    public var serviceIDs: [SalonService.ID]

    public init(
        id: ID = ID(),
        userID: User.ID? = nil,
        salonID: Salon.ID? = nil,
        displayName: String,
        title: String,
        biography: String = "",
        photoURL: URL? = nil,
        yearsOfExperience: Int = 0,
        specialties: [String] = [],
        languages: [String] = ["en"],
        certificates: [Certificate] = [],
        portfolio: [PortfolioItem] = [],
        instagramHandle: String? = nil,
        tikTokHandle: String? = nil,
        rating: Double = 0,
        reviewCount: Int = 0,
        averageResponseMinutes: Int? = nil,
        isFreelancer: Bool = false,
        serviceIDs: [SalonService.ID] = []
    ) {
        self.id = id
        self.userID = userID
        self.salonID = salonID
        self.displayName = displayName
        self.title = title
        self.biography = biography
        self.photoURL = photoURL
        self.yearsOfExperience = yearsOfExperience
        self.specialties = specialties
        self.languages = languages
        self.certificates = certificates
        self.portfolio = portfolio
        self.instagramHandle = instagramHandle
        self.tikTokHandle = tikTokHandle
        self.rating = rating
        self.reviewCount = reviewCount
        self.averageResponseMinutes = averageResponseMinutes
        self.isFreelancer = isFreelancer
        self.serviceIDs = serviceIDs
    }
}

public struct Certificate: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Certificate>

    public var id: ID
    public var title: String
    public var issuer: String
    public var issuedAt: Date
    public var documentURL: URL?

    public init(id: ID = ID(), title: String, issuer: String, issuedAt: Date, documentURL: URL? = nil) {
        self.id = id
        self.title = title
        self.issuer = issuer
        self.issuedAt = issuedAt
        self.documentURL = documentURL
    }
}

public struct PortfolioItem: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<PortfolioItem>

    public enum Kind: String, Codable, Hashable, Sendable {
        case photo
        case video
        case beforeAfter = "before_after"
    }

    public var id: ID
    public var kind: Kind
    public var mediaURL: URL
    /// For before/after items, the "before" image.
    public var beforeURL: URL?
    public var caption: String?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        kind: Kind,
        mediaURL: URL,
        beforeURL: URL? = nil,
        caption: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.mediaURL = mediaURL
        self.beforeURL = beforeURL
        self.caption = caption
        self.createdAt = createdAt
    }
}
