import Foundation

public enum PaymentMethodKind: String, Codable, Hashable, Sendable, CaseIterable {
    case applePay = "apple_pay"
    case card
    case bancontact
    case payPal = "paypal"
    case giftCard = "gift_card"
    case storeCredit = "store_credit"
    case cashOnSite = "cash_on_site"

    public var displayName: String {
        switch self {
        case .applePay: "Apple Pay"
        case .card: "Card"
        case .bancontact: "Bancontact"
        case .payPal: "PayPal"
        case .giftCard: "Gift Card"
        case .storeCredit: "Store Credit"
        case .cashOnSite: "Pay at Salon"
        }
    }

    public var symbolName: String {
        switch self {
        case .applePay: "apple.logo"
        case .card: "creditcard.fill"
        case .bancontact: "eurosign.circle.fill"
        case .payPal: "p.circle.fill"
        case .giftCard: "giftcard.fill"
        case .storeCredit: "wallet.pass.fill"
        case .cashOnSite: "banknote.fill"
        }
    }
}

/// A saved payment method (tokenized by Stripe; no PAN data ever on device).
public struct SavedPaymentMethod: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<SavedPaymentMethod>

    public var id: ID
    public var kind: PaymentMethodKind
    public var displayLabel: String
    /// Last four digits for cards.
    public var lastFour: String?
    public var expiryMonth: Int?
    public var expiryYear: Int?
    public var isDefault: Bool

    public init(
        id: ID = ID(),
        kind: PaymentMethodKind,
        displayLabel: String,
        lastFour: String? = nil,
        expiryMonth: Int? = nil,
        expiryYear: Int? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayLabel = displayLabel
        self.lastFour = lastFour
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.isDefault = isDefault
    }
}

public enum OrderStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case draft
    case awaitingPayment = "awaiting_payment"
    case partiallyPaid = "partially_paid"
    case paid
    case refunded
    case partiallyRefunded = "partially_refunded"
    case failed
    case cancelled
}

public struct OrderLine: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<OrderLine>

    public enum Kind: String, Codable, Hashable, Sendable {
        case service
        case product
        case membership
        case package
        case giftCard = "gift_card"
        case tip
        case fee
    }

    public var id: ID
    public var kind: Kind
    public var title: String
    public var quantity: Int
    public var unitPrice: Money
    public var referenceID: UUID?

    public init(
        id: ID = ID(),
        kind: Kind,
        title: String,
        quantity: Int = 1,
        unitPrice: Money,
        referenceID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.referenceID = referenceID
    }

    public var total: Money { unitPrice * Decimal(quantity) }
}

/// A payable order: services, products, memberships, tips.
public struct Order: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Order>

    public var id: ID
    public var salonID: Salon.ID
    public var clientID: User.ID
    public var appointmentID: Appointment.ID?
    public var lines: [OrderLine]
    public var status: OrderStatus
    /// Discount applied before tax (promo codes, prepayment discount, membership).
    public var discount: Money
    public var discountReason: String?
    /// VAT percent applied (e.g. 21 for Belgium).
    public var vatPercent: Decimal
    /// Portion of the total the client chose to pay now (deposits/partial payment).
    public var amountPaid: Money
    /// Reward points earned by this order.
    public var pointsEarned: Int
    public var currency: Currency
    public var createdAt: Date
    public var paidAt: Date?

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        clientID: User.ID,
        appointmentID: Appointment.ID? = nil,
        lines: [OrderLine] = [],
        status: OrderStatus = .draft,
        discount: Money = .zero(),
        discountReason: String? = nil,
        vatPercent: Decimal = 21,
        amountPaid: Money = .zero(),
        pointsEarned: Int = 0,
        currency: Currency = .eur,
        createdAt: Date = .now,
        paidAt: Date? = nil
    ) {
        self.id = id
        self.salonID = salonID
        self.clientID = clientID
        self.appointmentID = appointmentID
        self.lines = lines
        self.status = status
        self.discount = discount
        self.discountReason = discountReason
        self.vatPercent = vatPercent
        self.amountPaid = amountPaid
        self.pointsEarned = pointsEarned
        self.currency = currency
        self.createdAt = createdAt
        self.paidAt = paidAt
    }

    /// Sum of all lines before discount.
    public var subtotal: Money {
        lines.reduce(.zero(currency)) { $0 + $1.total }
    }

    /// Total due after discount (VAT included in prices, EU style).
    public var total: Money {
        let value = subtotal - discount
        return value.amount < 0 ? .zero(currency) : value
    }

    public var outstandingBalance: Money {
        let value = total - amountPaid
        return value.amount < 0 ? .zero(currency) : value
    }
}

public struct Refund: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Refund>

    public enum Reason: String, Codable, Hashable, Sendable, CaseIterable {
        case cancellation
        case serviceIssue = "service_issue"
        case duplicate
        case fraud
        case goodwill
    }

    public var id: ID
    public var orderID: Order.ID
    public var amount: Money
    public var reason: Reason
    public var note: String?
    /// True when issued automatically by cancellation rules.
    public var isAutomatic: Bool
    public var createdAt: Date

    public init(
        id: ID = ID(),
        orderID: Order.ID,
        amount: Money,
        reason: Reason,
        note: String? = nil,
        isAutomatic: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.orderID = orderID
        self.amount = amount
        self.reason = reason
        self.note = note
        self.isAutomatic = isAutomatic
        self.createdAt = createdAt
    }
}

public struct GiftCard: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<GiftCard>

    public var id: ID
    public var code: String
    public var salonID: Salon.ID?
    public var initialBalance: Money
    public var remainingBalance: Money
    public var purchaserID: User.ID?
    public var recipientEmail: String?
    public var message: String?
    public var expiresAt: Date?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        code: String,
        salonID: Salon.ID? = nil,
        initialBalance: Money,
        remainingBalance: Money,
        purchaserID: User.ID? = nil,
        recipientEmail: String? = nil,
        message: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.code = code
        self.salonID = salonID
        self.initialBalance = initialBalance
        self.remainingBalance = remainingBalance
        self.purchaserID = purchaserID
        self.recipientEmail = recipientEmail
        self.message = message
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// A movement on the client's Beauty Wallet.
public struct WalletTransaction: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<WalletTransaction>

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case payment
        case refund
        case cashback
        case storeCreditTopUp = "store_credit_top_up"
        case storeCreditSpend = "store_credit_spend"
        case giftCardRedemption = "gift_card_redemption"
        case rewardPoints = "reward_points"
    }

    public var id: ID
    public var userID: User.ID
    public var kind: Kind
    /// Positive = credit to the wallet, negative = debit.
    public var amount: Money
    public var points: Int
    public var title: String
    public var orderID: Order.ID?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        userID: User.ID,
        kind: Kind,
        amount: Money,
        points: Int = 0,
        title: String,
        orderID: Order.ID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.kind = kind
        self.amount = amount
        self.points = points
        self.title = title
        self.orderID = orderID
        self.createdAt = createdAt
    }
}

public struct Invoice: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Invoice>

    public var id: ID
    public var orderID: Order.ID
    public var number: String
    public var issuedAt: Date
    public var pdfURL: URL?

    public init(id: ID = ID(), orderID: Order.ID, number: String, issuedAt: Date = .now, pdfURL: URL? = nil) {
        self.id = id
        self.orderID = orderID
        self.number = number
        self.issuedAt = issuedAt
        self.pdfURL = pdfURL
    }
}
