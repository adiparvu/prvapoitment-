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

    /// The currency two operands agree on, or `nil` when they genuinely
    /// disagree.
    ///
    /// Zero is currency-agnostic — nothing is nothing in every currency — so a
    /// zero operand adopts the other's currency. That makes neutral seeds
    /// (`reduce(.zero())`) and defaulted zero fields safe in a non-euro order,
    /// while a real mismatch between two non-zero amounts still returns `nil`.
    ///
    /// When both sides are zero the left operand wins, so an expression like
    /// `subtotal - discount` keeps the subtotal's denomination rather than
    /// inheriting a defaulted euro from the right.
    private static func reconciledCurrency(_ lhs: Money, _ rhs: Money) -> Currency? {
        if lhs.currency == rhs.currency { return lhs.currency }
        if rhs.amount == 0 { return lhs.currency }
        if lhs.amount == 0 { return rhs.currency }
        return nil
    }

    // Arithmetic is defined for operands that share a currency (treating zero
    // as currency-agnostic); a true mismatch is a programmer error surfaced
    // immediately in debug builds.
    public static func + (lhs: Money, rhs: Money) -> Money {
        guard let currency = reconciledCurrency(lhs, rhs) else {
            assertionFailure("Currency mismatch: \(lhs.currency) + \(rhs.currency)")
            return lhs
        }
        return Money(lhs.amount + rhs.amount, currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        guard let currency = reconciledCurrency(lhs, rhs) else {
            assertionFailure("Currency mismatch: \(lhs.currency) - \(rhs.currency)")
            return lhs
        }
        return Money(lhs.amount - rhs.amount, currency)
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
    /// Orders two amounts. Zero compares against any currency, so
    /// `money > .zero()` works regardless of denomination.
    public static func < (lhs: Money, rhs: Money) -> Bool {
        assert(
            reconciledCurrency(lhs, rhs) != nil,
            "Currency mismatch: \(lhs.currency) < \(rhs.currency)"
        )
        return lhs.amount < rhs.amount
    }
}
