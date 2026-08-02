import Foundation
import PRVFoundation
import PRVModels

/// Exact minor-unit money arithmetic shared by every engine in this kit.
///
/// Money on this platform is `Decimal`, and every allocation performed here
/// converts to whole minor units (cents), distributes there, and converts
/// back. That guarantees the property the payments stack lives or dies by:
/// **a split never loses or invents a cent**. No `Double` ever touches money.
enum MoneyMath {
    /// All supported currencies are two-decimal.
    static let minorUnitScale = 2

    /// Minor units in one major unit (100 cents in one euro).
    static let minorUnitsPerMajor: Decimal = 100

    /// Banker's-rounds an amount to cents — the platform-wide currency rule.
    static func rounded(_ amount: Decimal) -> Decimal {
        amount.rounded(scale: minorUnitScale)
    }

    /// Converts an amount to whole minor units, banker's-rounded.
    ///
    /// Amounts far beyond any plausible salon order saturate rather than trap.
    static func minorUnits(_ amount: Decimal) -> Int {
        wholeNumber((amount * minorUnitsPerMajor).rounded(scale: 0))
    }

    /// Converts an integral decimal to `Int`, saturating instead of trapping.
    static func wholeNumber(_ value: Decimal) -> Int {
        let number = NSDecimalNumber(decimal: value)
        if number.compare(NSDecimalNumber(value: Int.max)) == .orderedDescending { return Int.max }
        if number.compare(NSDecimalNumber(value: Int.min)) == .orderedAscending { return Int.min }
        return number.intValue
    }

    /// Converts whole minor units back into money.
    static func money(_ units: Int, _ currency: Currency) -> Money {
        Money(Decimal(units) / minorUnitsPerMajor, currency)
    }

    /// Clamps an amount to zero. Payable money is never negative.
    static func clampedToZero(_ money: Money) -> Money {
        money.amount < 0 ? .zero(money.currency) : money
    }

    /// The smaller of two amounts (same currency by contract).
    static func lesser(_ lhs: Money, _ rhs: Money) -> Money {
        lhs.amount <= rhs.amount ? lhs : rhs
    }

    /// Re-denominates an amount into `currency` without converting it — used
    /// when callers hand in figures typed in a different currency case but
    /// meant for this order.
    static func denominated(_ money: Money, in currency: Currency) -> Money {
        money.currency == currency ? money : Money(money.amount, currency)
    }

    /// Clamps a percentage into `0...100`.
    static func clampPercent(_ percent: Decimal) -> Decimal {
        Swift.min(100, Swift.max(0, percent))
    }

    /// Clamps an integer percentage into `0...100`.
    static func clampPercent(_ percent: Int) -> Int {
        Swift.min(100, Swift.max(0, percent))
    }

    /// Floors a decimal toward negative infinity at integer scale.
    static func floored(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, .down)
        return result
    }

    // MARK: - Allocation

    /// Splits `total` minor units into `ways` parts that sum **exactly** to
    /// `total`. The remainder cents go to the earliest parts, one each, so
    /// 100.00 across three payers is 33.34 / 33.33 / 33.33.
    static func distribute(_ total: Int, ways: Int) -> [Int] {
        guard ways > 0 else { return [] }
        let base = total / ways
        let remainder = total % ways
        guard remainder != 0 else { return Array(repeating: base, count: ways) }
        // `remainder` carries the sign of `total`; hand out whole cents in the
        // same direction so the parts still sum exactly.
        let step = remainder > 0 ? 1 : -1
        let extras = abs(remainder)
        return (0 ..< ways).map { $0 < extras ? base + step : base }
    }

    /// Distributes `total` minor units across `weights` using the
    /// largest-remainder (Hamilton) method, so the parts sum **exactly** to
    /// `total` while staying as proportional as whole cents allow.
    ///
    /// Negative weights are treated as zero. When every weight is zero the
    /// total is split evenly instead, so no caller can be handed an empty or
    /// short allocation.
    static func allocate(_ total: Int, weights: [Decimal]) -> [Int] {
        guard !weights.isEmpty else { return [] }
        let positive = weights.map { Swift.max(0, $0) }
        let weightSum = positive.reduce(Decimal(0), +)
        guard weightSum > 0 else { return distribute(total, ways: positive.count) }

        var shares: [Int] = []
        var fractions: [(index: Int, value: Decimal)] = []
        var allocated = 0

        for (index, weight) in positive.enumerated() {
            let exact = Decimal(total) * weight / weightSum
            let floor = floored(exact)
            let units = wholeNumber(floor)
            shares.append(units)
            fractions.append((index, exact - floor))
            allocated += units
        }

        var leftover = total - allocated
        let ordered = fractions.sorted {
            $0.value == $1.value ? $0.index < $1.index : $0.value > $1.value
        }
        var cursor = 0
        while leftover > 0, !ordered.isEmpty {
            shares[ordered[cursor % ordered.count].index] += 1
            leftover -= 1
            cursor += 1
        }
        while leftover < 0, !ordered.isEmpty {
            shares[ordered[cursor % ordered.count].index] -= 1
            leftover += 1
            cursor += 1
        }
        return shares
    }
}
