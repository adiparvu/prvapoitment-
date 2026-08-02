import Foundation

public enum BusinessCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case hairSalon = "hair_salon"
    case nailStudio = "nail_studio"
    case lashStudio = "lash_studio"
    case browStudio = "brow_studio"
    case makeupStudio = "makeup_studio"
    case barbershop
    case spa
    case massage
    case esthetics
    case cosmeticClinic = "cosmetic_clinic"

    public var displayName: String {
        switch self {
        case .hairSalon: "Hair Salon"
        case .nailStudio: "Nail Studio"
        case .lashStudio: "Lash Studio"
        case .browStudio: "Brow Studio"
        case .makeupStudio: "Makeup Studio"
        case .barbershop: "Barbershop"
        case .spa: "Spa"
        case .massage: "Massage"
        case .esthetics: "Esthetics"
        case .cosmeticClinic: "Cosmetic Clinic"
        }
    }

    public var symbolName: String {
        switch self {
        case .hairSalon: "scissors"
        case .nailStudio: "hand.raised.fill"
        case .lashStudio: "eye.fill"
        case .browStudio: "eyebrow"
        case .makeupStudio: "paintbrush.pointed.fill"
        case .barbershop: "mustache.fill"
        case .spa: "leaf.fill"
        case .massage: "figure.mind.and.body"
        case .esthetics: "sparkles"
        case .cosmeticClinic: "cross.case.fill"
        }
    }
}

public enum SalonAmenity: String, Codable, Hashable, Sendable, CaseIterable {
    case parking
    case wheelchairAccess = "wheelchair_access"
    case petFriendly = "pet_friendly"
    case womenOnly = "women_only"
    case menOnly = "men_only"
    case luxury
    case premium
    case kidFriendly = "kid_friendly"
    case wifi
    case refreshments

    public var displayName: String {
        switch self {
        case .parking: "Parking"
        case .wheelchairAccess: "Wheelchair Access"
        case .petFriendly: "Pet Friendly"
        case .womenOnly: "Women Only"
        case .menOnly: "Men Only"
        case .luxury: "Luxury"
        case .premium: "Premium"
        case .kidFriendly: "Kid Friendly"
        case .wifi: "Wi-Fi"
        case .refreshments: "Refreshments"
        }
    }

    public var symbolName: String {
        switch self {
        case .parking: "car.fill"
        case .wheelchairAccess: "figure.roll"
        case .petFriendly: "pawprint.fill"
        case .womenOnly: "figure.stand.dress"
        case .menOnly: "figure.stand"
        case .luxury: "crown.fill"
        case .premium: "star.circle.fill"
        case .kidFriendly: "figure.and.child.holdinghands"
        case .wifi: "wifi"
        case .refreshments: "cup.and.saucer.fill"
        }
    }
}

public struct GeoCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct Address: Codable, Hashable, Sendable {
    public var street: String
    public var city: String
    public var postalCode: String
    public var country: String
    public var coordinate: GeoCoordinate

    public init(street: String, city: String, postalCode: String, country: String, coordinate: GeoCoordinate) {
        self.street = street
        self.city = city
        self.postalCode = postalCode
        self.country = country
        self.coordinate = coordinate
    }

    public var oneLine: String { "\(street), \(city)" }
}

/// Opening hours for one weekday. `nil` intervals means closed.
public struct OpeningHours: Codable, Hashable, Sendable {
    public struct Interval: Codable, Hashable, Sendable {
        /// Minutes from midnight, e.g. 540 = 09:00.
        public var openMinutes: Int
        public var closeMinutes: Int

        public init(openMinutes: Int, closeMinutes: Int) {
            self.openMinutes = openMinutes
            self.closeMinutes = closeMinutes
        }
    }

    /// 1 = Sunday … 7 = Saturday (matches `Calendar.component(.weekday)`).
    public var weekday: Int
    public var intervals: [Interval]

    public init(weekday: Int, intervals: [Interval]) {
        self.weekday = weekday
        self.intervals = intervals
    }

    public var isClosed: Bool { intervals.isEmpty }
}

public struct SalonPolicies: Codable, Hashable, Sendable {
    /// Hours before the appointment during which cancellation incurs a fee.
    public var freeCancellationHours: Int
    /// Fee charged for late cancellation, as a percentage of the order (0–100).
    public var lateCancellationFeePercent: Int
    /// Fee for no-shows, as a percentage of the order (0–100).
    public var noShowFeePercent: Int
    /// Minutes of grace before a late client is marked no-show.
    public var lateGraceMinutes: Int
    public var childrenAllowed: Bool
    public var notes: String?

    public init(
        freeCancellationHours: Int = 24,
        lateCancellationFeePercent: Int = 50,
        noShowFeePercent: Int = 100,
        lateGraceMinutes: Int = 10,
        childrenAllowed: Bool = true,
        notes: String? = nil
    ) {
        self.freeCancellationHours = freeCancellationHours
        self.lateCancellationFeePercent = lateCancellationFeePercent
        self.noShowFeePercent = noShowFeePercent
        self.lateGraceMinutes = lateGraceMinutes
        self.childrenAllowed = childrenAllowed
        self.notes = notes
    }
}

/// Configuration for prepayment incentives, set by the salon owner.
public struct PrepaymentPolicy: Codable, Hashable, Sendable {
    public enum Percent: Int, Codable, Hashable, Sendable, CaseIterable {
        case ten = 10, twenty = 20, thirty = 30, fifty = 50, full = 100
    }

    /// Prepayment levels the salon offers.
    public var offeredPercents: [Percent]
    /// Discount (0–100) granted when the client prepays in full.
    public var fullPrepaymentDiscountPercent: Int
    /// Reward-point multiplier applied to prepaid orders (e.g. 2 = double points).
    public var rewardPointsMultiplier: Int
    /// Cashback (0–100) credited to the Beauty Wallet on prepaid orders.
    public var cashbackPercent: Int
    /// Whether prepaying grants priority-booking status for the visit.
    public var grantsPriorityBooking: Bool

    public init(
        offeredPercents: [Percent] = [.twenty, .fifty, .full],
        fullPrepaymentDiscountPercent: Int = 10,
        rewardPointsMultiplier: Int = 2,
        cashbackPercent: Int = 2,
        grantsPriorityBooking: Bool = true
    ) {
        self.offeredPercents = offeredPercents
        self.fullPrepaymentDiscountPercent = fullPrepaymentDiscountPercent
        self.rewardPointsMultiplier = rewardPointsMultiplier
        self.cashbackPercent = cashbackPercent
        self.grantsPriorityBooking = grantsPriorityBooking
    }
}

public struct Salon: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Salon>

    public var id: ID
    public var name: String
    public var tagline: String?
    public var about: String
    public var categories: [BusinessCategory]
    public var address: Address
    public var phone: String?
    public var email: String?
    public var heroImageURL: URL?
    public var heroVideoURL: URL?
    public var galleryURLs: [URL]
    public var instagramHandle: String?
    public var tikTokHandle: String?
    public var virtualTourURL: URL?
    public var amenities: [SalonAmenity]
    public var languages: [String]
    public var openingHours: [OpeningHours]
    public var policies: SalonPolicies
    public var prepaymentPolicy: PrepaymentPolicy
    public var rating: Double
    public var reviewCount: Int
    public var isVerified: Bool
    public var currency: Currency
    /// Owning organization — groups locations for multi-salon businesses.
    public var organizationID: PRVID<Organization>?
    public var certificates: [String]
    public var awards: [String]
    public var createdAt: Date

    public init(
        id: ID = ID(),
        name: String,
        tagline: String? = nil,
        about: String = "",
        categories: [BusinessCategory],
        address: Address,
        phone: String? = nil,
        email: String? = nil,
        heroImageURL: URL? = nil,
        heroVideoURL: URL? = nil,
        galleryURLs: [URL] = [],
        instagramHandle: String? = nil,
        tikTokHandle: String? = nil,
        virtualTourURL: URL? = nil,
        amenities: [SalonAmenity] = [],
        languages: [String] = ["en"],
        openingHours: [OpeningHours] = [],
        policies: SalonPolicies = SalonPolicies(),
        prepaymentPolicy: PrepaymentPolicy = PrepaymentPolicy(),
        rating: Double = 0,
        reviewCount: Int = 0,
        isVerified: Bool = false,
        currency: Currency = .eur,
        organizationID: PRVID<Organization>? = nil,
        certificates: [String] = [],
        awards: [String] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.about = about
        self.categories = categories
        self.address = address
        self.phone = phone
        self.email = email
        self.heroImageURL = heroImageURL
        self.heroVideoURL = heroVideoURL
        self.galleryURLs = galleryURLs
        self.instagramHandle = instagramHandle
        self.tikTokHandle = tikTokHandle
        self.virtualTourURL = virtualTourURL
        self.amenities = amenities
        self.languages = languages
        self.openingHours = openingHours
        self.policies = policies
        self.prepaymentPolicy = prepaymentPolicy
        self.rating = rating
        self.reviewCount = reviewCount
        self.isVerified = isVerified
        self.currency = currency
        self.organizationID = organizationID
        self.certificates = certificates
        self.awards = awards
        self.createdAt = createdAt
    }
}

/// A multi-salon business entity (brand with multiple locations).
public struct Organization: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Organization>

    public var id: ID
    public var name: String
    public var ownerID: User.ID
    public var salonIDs: [Salon.ID]

    public init(id: ID = ID(), name: String, ownerID: User.ID, salonIDs: [Salon.ID] = []) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.salonIDs = salonIDs
    }
}
