import Foundation

/// Filterable, AI-augmentable salon search query.
public struct SalonSearchQuery: Codable, Hashable, Sendable {
    public enum Sort: String, Codable, Hashable, Sendable, CaseIterable {
        case recommended
        case distance
        case rating
        case priceLowToHigh = "price_asc"
        case priceHighToLow = "price_desc"
    }

    public enum AvailabilityWindow: String, Codable, Hashable, Sendable, CaseIterable {
        case anyTime = "any"
        case openNow = "open_now"
        case today
        case thisEvening = "this_evening"
    }

    public var text: String
    public var categories: [BusinessCategory]
    public var amenities: [SalonAmenity]
    public var languages: [String]
    public var near: GeoCoordinate?
    public var maxDistanceKm: Double?
    public var minRating: Double?
    public var maxPrice: Decimal?
    public var verifiedOnly: Bool
    public var availability: AvailabilityWindow
    public var sort: Sort

    public init(
        text: String = "",
        categories: [BusinessCategory] = [],
        amenities: [SalonAmenity] = [],
        languages: [String] = [],
        near: GeoCoordinate? = nil,
        maxDistanceKm: Double? = nil,
        minRating: Double? = nil,
        maxPrice: Decimal? = nil,
        verifiedOnly: Bool = false,
        availability: AvailabilityWindow = .anyTime,
        sort: Sort = .recommended
    ) {
        self.text = text
        self.categories = categories
        self.amenities = amenities
        self.languages = languages
        self.near = near
        self.maxDistanceKm = maxDistanceKm
        self.minRating = minRating
        self.maxPrice = maxPrice
        self.verifiedOnly = verifiedOnly
        self.availability = availability
        self.sort = sort
    }

    public var hasActiveFilters: Bool {
        !categories.isEmpty || !amenities.isEmpty || !languages.isEmpty
            || maxDistanceKm != nil || minRating != nil || maxPrice != nil
            || verifiedOnly || availability != .anyTime
    }
}
