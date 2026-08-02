import Foundation

/// A bookable service offered by a salon or freelancer.
public struct SalonService: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<SalonService>

    public var id: ID
    public var salonID: Salon.ID?
    public var name: String
    public var details: String
    public var category: BusinessCategory
    public var price: Money
    /// When set, the displayed price is "from `price`".
    public var isStartingPrice: Bool
    public var durationMinutes: Int
    /// Time to prepare the station before the service starts.
    public var preparationMinutes: Int
    /// Time to clean up after the service ends.
    public var cleanupMinutes: Int
    /// Extra buffer the salon wants between bookings of this service.
    public var bufferMinutes: Int
    public var imageURL: URL?
    public var isActive: Bool
    /// Whether a deposit/prepayment is required to book.
    public var requiresPrepayment: Bool
    public var addOns: [ServiceAddOn]

    public init(
        id: ID = ID(),
        salonID: Salon.ID? = nil,
        name: String,
        details: String = "",
        category: BusinessCategory,
        price: Money,
        isStartingPrice: Bool = false,
        durationMinutes: Int,
        preparationMinutes: Int = 0,
        cleanupMinutes: Int = 0,
        bufferMinutes: Int = 0,
        imageURL: URL? = nil,
        isActive: Bool = true,
        requiresPrepayment: Bool = false,
        addOns: [ServiceAddOn] = []
    ) {
        self.id = id
        self.salonID = salonID
        self.name = name
        self.details = details
        self.category = category
        self.price = price
        self.isStartingPrice = isStartingPrice
        self.durationMinutes = durationMinutes
        self.preparationMinutes = preparationMinutes
        self.cleanupMinutes = cleanupMinutes
        self.bufferMinutes = bufferMinutes
        self.imageURL = imageURL
        self.isActive = isActive
        self.requiresPrepayment = requiresPrepayment
        self.addOns = addOns
    }

    /// Total chair time this service occupies, including prep and cleanup.
    public var totalOccupancyMinutes: Int {
        preparationMinutes + durationMinutes + cleanupMinutes
    }
}

public struct ServiceAddOn: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<ServiceAddOn>

    public var id: ID
    public var name: String
    public var price: Money
    public var extraMinutes: Int

    public init(id: ID = ID(), name: String, price: Money, extraMinutes: Int = 0) {
        self.id = id
        self.name = name
        self.price = price
        self.extraMinutes = extraMinutes
    }
}
