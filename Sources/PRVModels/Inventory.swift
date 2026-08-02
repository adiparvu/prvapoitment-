import Foundation

public struct Product: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Product>

    public var id: ID
    public var salonID: Salon.ID
    public var name: String
    public var brand: String
    public var details: String
    public var barcode: String?
    public var retailPrice: Money
    public var costPrice: Money
    public var stockQuantity: Int
    public var lowStockThreshold: Int
    public var expiresAt: Date?
    public var supplierID: Supplier.ID?
    public var imageURL: URL?
    public var isRetail: Bool

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        name: String,
        brand: String,
        details: String = "",
        barcode: String? = nil,
        retailPrice: Money,
        costPrice: Money,
        stockQuantity: Int = 0,
        lowStockThreshold: Int = 5,
        expiresAt: Date? = nil,
        supplierID: Supplier.ID? = nil,
        imageURL: URL? = nil,
        isRetail: Bool = true
    ) {
        self.id = id
        self.salonID = salonID
        self.name = name
        self.brand = brand
        self.details = details
        self.barcode = barcode
        self.retailPrice = retailPrice
        self.costPrice = costPrice
        self.stockQuantity = stockQuantity
        self.lowStockThreshold = lowStockThreshold
        self.expiresAt = expiresAt
        self.supplierID = supplierID
        self.imageURL = imageURL
        self.isRetail = isRetail
    }

    public var isLowStock: Bool { stockQuantity <= lowStockThreshold }
}

public struct Supplier: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Supplier>

    public var id: ID
    public var name: String
    public var email: String?
    public var phone: String?

    public init(id: ID = ID(), name: String, email: String? = nil, phone: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
    }
}

public struct PurchaseOrder: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<PurchaseOrder>

    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case draft
        case sent
        case received
        case cancelled
    }

    public struct Line: Codable, Hashable, Sendable {
        public var productID: Product.ID
        public var productName: String
        public var quantity: Int
        public var unitCost: Money

        public init(productID: Product.ID, productName: String, quantity: Int, unitCost: Money) {
            self.productID = productID
            self.productName = productName
            self.quantity = quantity
            self.unitCost = unitCost
        }
    }

    public var id: ID
    public var salonID: Salon.ID
    public var supplierID: Supplier.ID
    public var lines: [Line]
    public var status: Status
    public var createdAt: Date
    public var expectedAt: Date?

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        supplierID: Supplier.ID,
        lines: [Line] = [],
        status: Status = .draft,
        createdAt: Date = .now,
        expectedAt: Date? = nil
    ) {
        self.id = id
        self.salonID = salonID
        self.supplierID = supplierID
        self.lines = lines
        self.status = status
        self.createdAt = createdAt
        self.expectedAt = expectedAt
    }

    public var totalCost: Money {
        lines.reduce(.zero()) { $0 + ($1.unitCost * Decimal($1.quantity)) }
    }
}
