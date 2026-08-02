import Foundation
import PRVFoundation
import PRVModels

/// Everything that follows from one prepayment choice: what is charged today,
/// what is left for the salon, and which incentives the salon grants in return.
///
/// The money invariant is exact: `payNow + payLater + discount == orderTotal`.
public struct PrepaymentQuote: Hashable, Sendable, Identifiable {
    /// The level the client picked, or `nil` for "pay at the salon".
    public let percent: PrepaymentPolicy.Percent?
    /// The order total this quote was calculated from, before any prepayment
    /// discount.
    public let orderTotal: Money
    /// The reduction granted for prepaying (full prepayment only).
    public let discount: Money
    /// Charged immediately at checkout.
    public let payNow: Money
    /// Settled at the salon on the day.
    public let payLater: Money
    /// Credited to the Beauty Wallet once the prepayment clears.
    public let cashback: Money
    /// Reward-point multiplier applied to the order (never below 1).
    public let pointsMultiplier: Int
    /// Whether this level grants priority-booking status for the visit.
    public let grantsPriority: Bool

    /// Creates a quote. Produced by ``PrepaymentCalculator``; the memberwise
    /// initializer is public so callers can build fixtures.
    public init(
        percent: PrepaymentPolicy.Percent?,
        orderTotal: Money,
        discount: Money,
        payNow: Money,
        payLater: Money,
        cashback: Money,
        pointsMultiplier: Int,
        grantsPriority: Bool
    ) {
        self.percent = percent
        self.orderTotal = orderTotal
        self.discount = discount
        self.payNow = payNow
        self.payLater = payLater
        self.cashback = cashback
        self.pointsMultiplier = pointsMultiplier
        self.grantsPriority = grantsPriority
    }

    /// `0` for "pay at the salon", otherwise the prepayment percentage.
    public var id: Int { percent?.rawValue ?? 0 }

    /// Whether the client is paying anything up front.
    public var isPrepaid: Bool { percent != nil }

    /// Whether the client is settling the whole order now.
    public var isFullPrepayment: Bool { percent == .full }

    /// What the order actually costs after the prepayment discount.
    public var payableTotal: Money { payNow + payLater }

    /// Whether this level carries any incentive worth highlighting.
    public var hasIncentives: Bool {
        !discount.isZero || !cashback.isZero || pointsMultiplier > 1 || grantsPriority
    }

    /// Card title, e.g. `"Prepay 50%"`, `"Pay in full"`, `"Pay at the salon"`.
    public var title: String {
        guard let percent else { return "Pay at the salon" }
        return percent == .full ? "Pay in full" : "Prepay \(percent.rawValue)%"
    }

    /// One-line summary of what happens at checkout.
    public var subtitle: String {
        isPrepaid ? "\(payNow.formatted) today" : "Nothing is charged now"
    }
}

/// Turns a salon's ``PrepaymentPolicy`` and a prepayment level into an exact
/// quote.
///
/// The rules, as sold to clients:
/// - **Full prepayment** earns `fullPrepaymentDiscountPercent` off the order.
///   Partial deposits keep the list price — the salon discounts certainty,
///   not instalments.
/// - **Every prepaid order** earns `cashbackPercent` of the prepaid amount
///   back to the Beauty Wallet and the policy's reward-point multiplier.
/// - **Paying at the salon** earns nothing and charges nothing up front.
///
/// Deterministic and pure: same policy, same level, same total, same cents.
public struct PrepaymentCalculator: Sendable {
    /// Creates a calculator.
    public init() {}

    /// Quotes one prepayment level.
    /// - Parameters:
    ///   - policy: The salon's prepayment configuration.
    ///   - percent: The level chosen, or `nil` to pay at the salon.
    ///   - orderTotal: Order total before any prepayment discount; negatives
    ///     clamp to zero.
    public func quote(
        policy: PrepaymentPolicy,
        percent: PrepaymentPolicy.Percent?,
        orderTotal: Money
    ) -> PrepaymentQuote {
        let total = MoneyMath.clampedToZero(orderTotal)
        let currency = total.currency

        guard let percent else {
            return PrepaymentQuote(
                percent: nil,
                orderTotal: total,
                discount: .zero(currency),
                payNow: .zero(currency),
                payLater: total,
                cashback: .zero(currency),
                pointsMultiplier: 1,
                grantsPriority: false
            )
        }

        let discount = Self.discount(for: percent, total: total, policy: policy)
        let payable = MoneyMath.clampedToZero(total - discount)
        let payNow = percent == .full
            ? payable
            : MoneyMath.lesser(payable.percentage(Decimal(percent.rawValue)), payable)
        let payLater = MoneyMath.clampedToZero(payable - payNow)

        let cashbackPercent = MoneyMath.clampPercent(policy.cashbackPercent)
        let cashback = cashbackPercent > 0
            ? payNow.percentage(Decimal(cashbackPercent))
            : Money.zero(currency)

        return PrepaymentQuote(
            percent: percent,
            orderTotal: total,
            discount: discount,
            payNow: payNow,
            payLater: payLater,
            cashback: cashback,
            pointsMultiplier: Swift.max(1, policy.rewardPointsMultiplier),
            grantsPriority: policy.grantsPriorityBooking
        )
    }

    /// Every level the salon offers for this total, in ascending order,
    /// always ending with the "pay at the salon" fallback.
    public func quotes(policy: PrepaymentPolicy, orderTotal: Money) -> [PrepaymentQuote] {
        let offered = PrepaymentPolicy.Percent.allCases
            .filter { policy.offeredPercents.contains($0) }
            .map { quote(policy: policy, percent: $0, orderTotal: orderTotal) }
        return offered + [quote(policy: policy, percent: nil, orderTotal: orderTotal)]
    }

    /// The reduction a prepayment level earns.
    ///
    /// Only full prepayment is discounted, and never by more than the total.
    public static func discount(
        for percent: PrepaymentPolicy.Percent?,
        total: Money,
        policy: PrepaymentPolicy
    ) -> Money {
        let base = MoneyMath.clampedToZero(total)
        guard percent == .full else { return .zero(base.currency) }
        let rate = MoneyMath.clampPercent(policy.fullPrepaymentDiscountPercent)
        guard rate > 0 else { return .zero(base.currency) }
        return MoneyMath.lesser(base.percentage(Decimal(rate)), base)
    }

    /// The minimum a client must pay now to satisfy a salon that requires a
    /// deposit, i.e. the smallest level it offers. `nil` when the salon offers
    /// no prepayment at all.
    public func minimumDeposit(policy: PrepaymentPolicy, orderTotal: Money) -> Money? {
        guard let smallest = policy.offeredPercents.min(by: { $0.rawValue < $1.rawValue }) else {
            return nil
        }
        return quote(policy: policy, percent: smallest, orderTotal: orderTotal).payNow
    }

    /// Reward points an order earns at a given prepayment level: one point per
    /// whole unit of currency, multiplied when the client prepays.
    public func rewardPoints(
        for orderTotal: Money,
        percent: PrepaymentPolicy.Percent?,
        policy: PrepaymentPolicy
    ) -> Int {
        let quote = quote(policy: policy, percent: percent, orderTotal: orderTotal)
        return PricingEngine.points(for: quote.payableTotal, multiplier: quote.pointsMultiplier)
    }
}
