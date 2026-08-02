import Foundation
import PRVFoundation
import PRVModels

/// One benefit line rendered inside a prepayment card.
struct PrepaymentBenefit: Identifiable, Hashable, Sendable {
    /// The kind of incentive, which drives the accent used by the card.
    enum Kind: Hashable, Sendable {
        case discount
        case points
        case cashback
        case priority
        case neutral
    }

    var kind: Kind
    var symbolName: String
    var text: String

    var id: String { "\(text)-\(symbolName)" }
}

/// A prepayment level the client can choose, with every consequence of that
/// choice pre-computed: what is charged today, what remains for the salon,
/// and which incentives the salon grants in return.
///
/// `percent == nil` represents "Pay at the salon".
struct PrepaymentOption: Identifiable, Hashable, Sendable {
    var percent: PrepaymentPolicy.Percent?
    /// Charged at checkout, immediately after confirming.
    var amountDueNow: Money
    /// Settled in the salon on the day.
    var amountDueAtSalon: Money
    /// Price reduction granted for this prepayment level.
    var discount: Money
    /// Wallet cashback credited on the prepaid amount.
    var cashback: Money
    /// Reward-point multiplier applied to the order.
    var pointsMultiplier: Int
    /// Whether this level grants priority-booking status for the visit.
    var grantsPriority: Bool
    var benefits: [PrepaymentBenefit]

    var id: Int { percent?.rawValue ?? 0 }

    /// Card title, e.g. `"Prepay 50%"` or `"Pay at the salon"`.
    var title: String {
        guard let percent else { return "Pay at the salon" }
        return percent == .full ? "Pay in full" : "Prepay \(percent.rawValue)%"
    }

    /// One-line description of what happens at checkout.
    var subtitle: String {
        guard percent != nil else { return "Nothing is charged now" }
        return "\(amountDueNow.formatted) today"
    }

    /// Whether this option carries any incentive worth highlighting.
    var isIncentivized: Bool {
        !discount.isZero || !cashback.isZero || pointsMultiplier > 1 || grantsPriority
    }
}

/// Computes prepayment options and reward points from a salon's
/// ``PrepaymentPolicy``.
///
/// - Note: This mirrors the pricing rules that belong in `PRVPaymentsKit`.
///   The kit is not on disk yet, so the booking flow computes the display
///   values locally; swap this type for the kit's pricing engine once it
///   lands so the client and the server share one implementation.
enum PrepaymentPricing {
    /// Every option a salon offers for the given order total, always ending
    /// with the "Pay at the salon" fallback.
    /// - Parameters:
    ///   - total: Order total before any prepayment discount.
    ///   - policy: The salon's prepayment configuration.
    static func options(total: Money, policy: PrepaymentPolicy) -> [PrepaymentOption] {
        let offered = PrepaymentPolicy.Percent.allCases
            .filter { policy.offeredPercents.contains($0) }
        return offered.map { option(for: $0, total: total, policy: policy) }
            + [payAtSalon(total: total)]
    }

    /// The option for one prepayment level.
    static func option(
        for percent: PrepaymentPolicy.Percent,
        total: Money,
        policy: PrepaymentPolicy
    ) -> PrepaymentOption {
        let discount = discount(for: percent, total: total, policy: policy)
        let payable = total - discount
        let dueNow = percent == .full
            ? payable
            : payable.percentage(Decimal(percent.rawValue))
        let remainder = payable - dueNow
        let dueAtSalon = remainder.amount < 0 ? Money.zero(total.currency) : remainder
        let cashback = policy.cashbackPercent > 0
            ? dueNow.percentage(Decimal(policy.cashbackPercent))
            : Money.zero(total.currency)
        let multiplier = max(1, policy.rewardPointsMultiplier)

        var benefits: [PrepaymentBenefit] = []
        if !discount.isZero {
            benefits.append(PrepaymentBenefit(
                kind: .discount,
                symbolName: "tag.fill",
                text: "Save \(discount.formatted) (\(policy.fullPrepaymentDiscountPercent)% off)"
            ))
        }
        if multiplier > 1 {
            benefits.append(PrepaymentBenefit(
                kind: .points,
                symbolName: "sparkles",
                text: "\(multiplier)× reward points"
            ))
        }
        if !cashback.isZero {
            benefits.append(PrepaymentBenefit(
                kind: .cashback,
                symbolName: "wallet.pass.fill",
                text: "\(cashback.formatted) cashback to your wallet"
            ))
        }
        if policy.grantsPriorityBooking {
            benefits.append(PrepaymentBenefit(
                kind: .priority,
                symbolName: "bolt.fill",
                text: "Priority booking for this visit"
            ))
        }
        if !dueAtSalon.isZero {
            benefits.append(PrepaymentBenefit(
                kind: .neutral,
                symbolName: "banknote.fill",
                text: "\(dueAtSalon.formatted) at the salon"
            ))
        }

        return PrepaymentOption(
            percent: percent,
            amountDueNow: dueNow,
            amountDueAtSalon: dueAtSalon,
            discount: discount,
            cashback: cashback,
            pointsMultiplier: multiplier,
            grantsPriority: policy.grantsPriorityBooking,
            benefits: benefits
        )
    }

    /// The always-available "pay on the day" option.
    static func payAtSalon(total: Money) -> PrepaymentOption {
        PrepaymentOption(
            percent: nil,
            amountDueNow: .zero(total.currency),
            amountDueAtSalon: total,
            discount: .zero(total.currency),
            cashback: .zero(total.currency),
            pointsMultiplier: 1,
            grantsPriority: false,
            benefits: [
                PrepaymentBenefit(
                    kind: .neutral,
                    symbolName: "banknote.fill",
                    text: "\(total.formatted) settled on the day"
                ),
            ]
        )
    }

    /// The price reduction granted for a prepayment level. Salons discount
    /// full prepayment only; partial deposits keep the list price.
    static func discount(
        for percent: PrepaymentPolicy.Percent?,
        total: Money,
        policy: PrepaymentPolicy
    ) -> Money {
        guard percent == .full, policy.fullPrepaymentDiscountPercent > 0 else {
            return .zero(total.currency)
        }
        return total.percentage(Decimal(policy.fullPrepaymentDiscountPercent))
    }

    /// Reward points earned by an order: one point per unit of currency,
    /// multiplied when the client prepays.
    static func points(for total: Money, percent: PrepaymentPolicy.Percent?, policy: PrepaymentPolicy) -> Int {
        let base = max(0, Int(total.amount.doubleValue))
        guard percent != nil else { return base }
        return base * max(1, policy.rewardPointsMultiplier)
    }
}

/// Computes the value of a coupon against an order subtotal.
enum CouponPricing {
    /// The monetary reduction a coupon grants, clamped to the subtotal.
    /// Returns zero when the coupon's minimum spend is not met.
    static func discount(_ coupon: Coupon, subtotal: Money) -> Money {
        guard meetsMinimumSpend(coupon, subtotal: subtotal) else { return .zero(subtotal.currency) }
        let raw: Money
        switch coupon.discount {
        case .percent(let value):
            raw = subtotal.percentage(Decimal(value))
        case .fixed(let money):
            raw = Money(money.amount, subtotal.currency)
        }
        return raw > subtotal ? subtotal : raw
    }

    /// Whether the subtotal clears the coupon's minimum-spend requirement.
    static func meetsMinimumSpend(_ coupon: Coupon, subtotal: Money) -> Bool {
        guard let minimum = coupon.minimumSpend else { return true }
        return subtotal.amount >= minimum.amount
    }
}
