import Foundation
import PRVFoundation

public enum Currency: String, Codable, Hashable, Sendable, CaseIterable {
    case eur = "EUR"
    case usd = "USD"
    case gbp = "GBP"
    case chf = "CHF"
    case ron = "RON"

    public var symbol: String {
        switch self {
        case .eur: "€"
        case .usd: "$"
        case .gbp: "£"
        case .chf: "CHF"
        case .ron: "lei"
        }
    }
}

/// An exact monetary amount. All money math uses `Decimal` — never `Double`.
public struct Money: Codable, Hashable, Sendable {
    public var amount: Decimal
    public var currency: Currency

    public init(_ amount: Decimal, _ currency: Currency = .eur) {
        self.amount = amount
        self.currency = currency
    }

    public static func zero(_ currency: Currency = .eur) -> Money {
        Money(0, currency)
    }

    public var isZero: Bool { amount == 0 }

    /// Localized display string, e.g. "€45.00".
    public var formatted: String {
        amount.doubleValue.formatted(.currency(code: currency.rawValue))
    }

    // Arithmetic is only defined for same-currency operands; mixing currencies
    // is a programmer error surfaced immediately in debug builds.
    public static func + (lhs: Money, rhs: Money) -> Money {
        assert(lhs.currency == rhs.currency, "Currency mismatch")
        return Money(lhs.amount + rhs.amount, lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        assert(lhs.currency == rhs.currency, "Currency mismatch")
        return Money(lhs.amount - rhs.amount, lhs.currency)
    }

    public static func * (lhs: Money, rhs: Decimal) -> Money {
        Money((lhs.amount * rhs).rounded(), lhs.currency)
    }

    /// Applies a percentage (0–100) and returns the resulting amount.
    public func percentage(_ percent: Decimal) -> Money {
        Money((amount * percent / 100).rounded(), currency)
    }
}

extension Money: Comparable {
    public static func < (lhs: Money, rhs: Money) -> Bool {
        assert(lhs.currency == rhs.currency, "Currency mismatch")
        return lhs.amount < rhs.amount
    }
}
