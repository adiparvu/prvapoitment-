import Foundation
import CoreLocation
import PRVModels

// Discover-local display metadata and geo helpers for shared model types.
// These stay `internal` by module-ownership rules; promote to PRVModels if
// another feature ever needs them.

extension SalonSearchQuery.Sort {
    /// Human-readable menu label.
    var displayName: String {
        switch self {
        case .recommended: "Recommended"
        case .distance: "Distance"
        case .rating: "Top Rated"
        case .priceLowToHigh: "Price: Low to High"
        case .priceHighToLow: "Price: High to Low"
        }
    }
}

extension SalonSearchQuery.AvailabilityWindow {
    /// Human-readable chip label.
    var displayName: String {
        switch self {
        case .anyTime: "Any Time"
        case .openNow: "Open Now"
        case .today: "Today"
        case .thisEvening: "This Evening"
        }
    }

    /// SF Symbol for the chip.
    var symbolName: String {
        switch self {
        case .anyTime: "infinity"
        case .openNow: "clock.fill"
        case .today: "sun.max.fill"
        case .thisEvening: "moon.stars.fill"
        }
    }

    /// The windows worth offering as quick chips ("any" is the absence of one).
    static var quickChoices: [SalonSearchQuery.AvailabilityWindow] {
        [.openNow, .today, .thisEvening]
    }
}

extension SalonSearchQuery {
    /// How many structured filters are active — drives the "Filters" badge.
    var activeFilterCount: Int {
        var count = categories.count + amenities.count + languages.count
        if maxDistanceKm != nil { count += 1 }
        if minRating != nil { count += 1 }
        if maxPrice != nil { count += 1 }
        if verifiedOnly { count += 1 }
        if availability != .anyTime { count += 1 }
        return count
    }
}

extension GeoCoordinate {
    /// MapKit-compatible coordinate.
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Great-circle distance to another coordinate, in kilometers.
    func distanceKm(to other: GeoCoordinate) -> Double {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let there = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return here.distance(from: there) / 1_000
    }
}

/// Language filter choices offered in the filter sheet, as ISO 639-1 codes.
enum DiscoverLanguages {
    static let choices = ["en", "fr", "nl", "de", "es", "it", "pt", "ar"]

    /// Localized display name for a language code, e.g. "en" → "English".
    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}
