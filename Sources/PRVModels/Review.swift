import Foundation

public struct Review: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Review>

    public enum ModerationStatus: String, Codable, Hashable, Sendable {
        case pending
        case approved
        case flagged
        case removed
    }

    public var id: ID
    public var salonID: Salon.ID
    public var professionalID: Professional.ID?
    public var authorID: User.ID
    public var authorName: String
    public var authorAvatarURL: URL?
    /// 1…5.
    public var rating: Int
    public var text: String
    public var photoURLs: [URL]
    public var videoURLs: [URL]
    /// Set when the review comes from a completed, paid appointment.
    public var verifiedAppointmentID: Appointment.ID?
    public var likeCount: Int
    public var likedByMe: Bool
    public var ownerResponse: String?
    public var ownerRespondedAt: Date?
    public var moderation: ModerationStatus
    public var createdAt: Date

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        professionalID: Professional.ID? = nil,
        authorID: User.ID,
        authorName: String,
        authorAvatarURL: URL? = nil,
        rating: Int,
        text: String,
        photoURLs: [URL] = [],
        videoURLs: [URL] = [],
        verifiedAppointmentID: Appointment.ID? = nil,
        likeCount: Int = 0,
        likedByMe: Bool = false,
        ownerResponse: String? = nil,
        ownerRespondedAt: Date? = nil,
        moderation: ModerationStatus = .approved,
        createdAt: Date = .now
    ) {
        self.id = id
        self.salonID = salonID
        self.professionalID = professionalID
        self.authorID = authorID
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.rating = rating
        self.text = text
        self.photoURLs = photoURLs
        self.videoURLs = videoURLs
        self.verifiedAppointmentID = verifiedAppointmentID
        self.likeCount = likeCount
        self.likedByMe = likedByMe
        self.ownerResponse = ownerResponse
        self.ownerRespondedAt = ownerRespondedAt
        self.moderation = moderation
        self.createdAt = createdAt
    }

    public var isVerified: Bool { verifiedAppointmentID != nil }
}

public struct ReviewComment: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ReviewComment>

    public var id: ID
    public var reviewID: Review.ID
    public var authorID: User.ID
    public var authorName: String
    public var text: String
    public var createdAt: Date

    public init(
        id: ID = ID(),
        reviewID: Review.ID,
        authorID: User.ID,
        authorName: String,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.reviewID = reviewID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
    }
}
