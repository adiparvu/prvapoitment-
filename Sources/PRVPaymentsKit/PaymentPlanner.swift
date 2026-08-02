import Foundation
import PRVFoundation
import PRVModels

// MARK: - Split payments

/// Someone sharing the bill.
public struct SplitPayer: Hashable, Sendable, Identifiable {
    /// The platform account paying, when they have one (guests may not).
    public var userID: User.ID?
    /// Display name for the share row.
    public var name: String
    /// Relative weight of this payer's share. Equal weights split evenly;
    /// itemized splits pass each payer's own consumption here.
    public var weight: Decimal

    /// Creates a payer.
    public init(userID: User.ID? = nil, name: String, weight: Decimal = 1) {
        self.userID = userID
        self.name = name
        self.weight = weight
    }

    public var id: String { userID.map(\.description) ?? name }
}

/// One payer's slice of a split bill.
public struct PaymentShare: Hashable, Sendable, Identifiable {
    /// Position in the split, starting at zero.
    public let id: Int
    /// The account paying, when known.
    public let payerID: User.ID?
    /// Row label, e.g. `"Sofia"` or `"Payer 2"`.
    public let label: String
    /// Exactly what this payer owes.
    public let amount: Money

    /// Creates a share.
    public init(id: Int, payerID: User.ID?, label: String, amount: Money) {
        self.id = id
        self.payerID = payerID
        self.label = label
        self.amount = amount
    }
}

/// A bill split across payers.
///
/// The shares always sum to the total **to the cent** — that is the whole
/// point of this type, and ``isExact`` proves it at runtime.
public struct SplitPlan: Hashable, Sendable {
    /// The amount being split.
    public let total: Money
    /// Each payer's slice, in payer order.
    public let shares: [PaymentShare]

    /// Creates a plan.
    public init(total: Money, shares: [PaymentShare]) {
        self.total = total
        self.shares = shares
    }

    /// Sum of every share.
    public var allocated: Money {
        shares.reduce(Money.zero(total.currency)) { $0 + $1.amount }
    }

    /// Whether the shares reconcile exactly with the total.
    public var isExact: Bool { allocated.amount == total.amount }

    /// The largest share — the payer who absorbed a remainder cent.
    public var largestShare: Money? { shares.map(\.amount).max() }
}

// MARK: - Schedules

/// One dated payment in a schedule.
public struct PaymentInstallment: Hashable, Sendable, Identifiable {
    /// The role this payment plays.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Secures the booking.
        case deposit
        /// Settles what the deposit left.
        case balance
        /// One of several equal payments.
        case installment
    }

    /// Position in the schedule, starting at zero.
    public let id: Int
    /// The role this payment plays.
    public let kind: Kind
    /// Row label, e.g. `"Deposit"` or `"Payment 2 of 3"`.
    public let label: String
    /// Exactly what is charged on this date.
    public let amount: Money
    /// When it falls due.
    public let dueAt: Date

    /// Creates an installment.
    public init(id: Int, kind: Kind, label: String, amount: Money, dueAt: Date) {
        self.id = id
        self.kind = kind
        self.label = label
        self.amount = amount
        self.dueAt = dueAt
    }
}

/// A dated plan for settling one order.
///
/// Like ``SplitPlan``, the installments sum to the total to the cent.
public struct PaymentSchedule: Hashable, Sendable {
    /// The amount being scheduled.
    public let total: Money
    /// Payments in chronological order.
    public let installments: [PaymentInstallment]

    /// Creates a schedule.
    public init(total: Money, installments: [PaymentInstallment]) {
        self.total = total
        self.installments = installments
    }

    /// Sum of every installment.
    public var allocated: Money {
        installments.reduce(Money.zero(total.currency)) { $0 + $1.amount }
    }

    /// Whether the installments reconcile exactly with the total.
    public var isExact: Bool { allocated.amount == total.amount }

    /// The deposit, when this is a deposit-then-balance schedule.
    public var deposit: PaymentInstallment? {
        installments.first { $0.kind == .deposit }
    }

    /// The closing balance, when this is a deposit-then-balance schedule.
    public var balance: PaymentInstallment? {
        installments.first { $0.kind == .balance }
    }

    /// What is charged today, i.e. every installment due at or before `date`.
    public func amountDue(by date: Date) -> Money {
        installments
            .filter { $0.dueAt <= date }
            .reduce(Money.zero(total.currency)) { $0 + $1.amount }
    }
}

// MARK: - Planner

/// Builds split payments and payment schedules that always reconcile.
///
/// Every allocation runs through whole minor units, so remainder cents are
/// distributed deterministically instead of being rounded into existence or
/// out of it. €100.00 across three friends is €33.34 / €33.33 / €33.33 — never
/// €33.33 three times with a cent left stranded on the salon's books.
public struct PaymentPlanner: Sendable {
    /// Creates a planner.
    public init() {}

    // MARK: Splitting

    /// Splits an amount evenly across `ways` anonymous payers.
    ///
    /// Remainder cents go to the earliest shares, one each.
    /// - Parameters:
    ///   - total: The amount to split; negatives clamp to zero.
    ///   - ways: How many payers. Fewer than one yields an empty plan.
    public func splitEvenly(total: Money, ways: Int) -> SplitPlan {
        let amount = MoneyMath.clampedToZero(total)
        guard ways > 0 else { return SplitPlan(total: amount, shares: []) }
        let units = MoneyMath.distribute(MoneyMath.minorUnits(amount.amount), ways: ways)
        let shares = units.enumerated().map { index, value in
            PaymentShare(
                id: index,
                payerID: nil,
                label: "Payer \(index + 1)",
                amount: MoneyMath.money(value, amount.currency)
            )
        }
        return SplitPlan(total: amount, shares: shares)
    }

    /// Splits an amount evenly across named payers, keeping their identities
    /// on the shares so each can be charged separately.
    public func splitEvenly(total: Money, among payers: [SplitPayer]) -> SplitPlan {
        let amount = MoneyMath.clampedToZero(total)
        guard !payers.isEmpty else { return SplitPlan(total: amount, shares: []) }
        let units = MoneyMath.distribute(MoneyMath.minorUnits(amount.amount), ways: payers.count)
        return SplitPlan(total: amount, shares: shares(from: units, payers: payers, currency: amount.currency))
    }

    /// Splits an amount in proportion to each payer's weight — an itemized
    /// split where everyone pays for what they had.
    ///
    /// Uses the largest-remainder method: shares stay as proportional as whole
    /// cents allow and still sum exactly to the total. Payers with zero or
    /// negative weight pay nothing; if every weight is zero the bill splits
    /// evenly instead.
    public func split(total: Money, among payers: [SplitPayer]) -> SplitPlan {
        let amount = MoneyMath.clampedToZero(total)
        guard !payers.isEmpty else { return SplitPlan(total: amount, shares: []) }
        let units = MoneyMath.allocate(
            MoneyMath.minorUnits(amount.amount),
            weights: payers.map(\.weight)
        )
        return SplitPlan(total: amount, shares: shares(from: units, payers: payers, currency: amount.currency))
    }

    /// Splits an amount in proportion to per-payer consumption, e.g. what each
    /// person's services came to.
    public func split(total: Money, byAmounts amounts: [Money]) -> SplitPlan {
        let payers = amounts.enumerated().map { index, value in
            SplitPayer(name: "Payer \(index + 1)", weight: Swift.max(0, value.amount))
        }
        return split(total: total, among: payers)
    }

    // MARK: Deposit schedules

    /// A deposit today, the balance on the day of the visit.
    ///
    /// The balance is derived by subtraction, so deposit + balance is exactly
    /// the total no matter how the percentage rounds.
    /// - Parameters:
    ///   - total: The order total; negatives clamp to zero.
    ///   - depositPercent: Percentage taken up front, clamped to `0...100`.
    ///   - depositDueAt: When the deposit is charged (usually now).
    ///   - balanceDueAt: When the balance falls due (usually the appointment).
    public func depositSchedule(
        total: Money,
        depositPercent: Int,
        depositDueAt: Date,
        balanceDueAt: Date
    ) -> PaymentSchedule {
        let amount = MoneyMath.clampedToZero(total)
        let percent = MoneyMath.clampPercent(depositPercent)
        let deposit = amount.percentage(Decimal(percent))
        return depositSchedule(
            total: amount,
            deposit: deposit,
            depositDueAt: depositDueAt,
            balanceDueAt: balanceDueAt
        )
    }

    /// A fixed deposit today, the balance on the day of the visit.
    ///
    /// A deposit at or above the total collapses the schedule to a single
    /// payment; a deposit of zero collapses it to the balance alone.
    public func depositSchedule(
        total: Money,
        deposit: Money,
        depositDueAt: Date,
        balanceDueAt: Date
    ) -> PaymentSchedule {
        let amount = MoneyMath.clampedToZero(total)
        let currency = amount.currency
        let upFront = MoneyMath.lesser(
            MoneyMath.clampedToZero(MoneyMath.denominated(deposit, in: currency)),
            amount
        )
        let balance = MoneyMath.clampedToZero(amount - upFront)

        var installments: [PaymentInstallment] = []
        if !upFront.isZero || balance.isZero {
            installments.append(
                PaymentInstallment(
                    id: installments.count,
                    kind: .deposit,
                    label: balance.isZero ? "Paid in full" : "Deposit",
                    amount: upFront,
                    dueAt: depositDueAt
                )
            )
        }
        if !balance.isZero {
            installments.append(
                PaymentInstallment(
                    id: installments.count,
                    kind: .balance,
                    label: "Balance at the salon",
                    amount: balance,
                    dueAt: balanceDueAt
                )
            )
        }
        return PaymentSchedule(total: amount, installments: installments)
    }

    /// A deposit-then-balance schedule derived from a prepayment quote, so the
    /// schedule the client sees is the one the pricing engine quoted.
    public func schedule(
        for quote: PrepaymentQuote,
        depositDueAt: Date,
        balanceDueAt: Date
    ) -> PaymentSchedule {
        depositSchedule(
            total: quote.payableTotal,
            deposit: quote.payNow,
            depositDueAt: depositDueAt,
            balanceDueAt: balanceDueAt
        )
    }

    // MARK: Instalment schedules

    /// Splits an amount into `count` equal payments spaced `intervalDays`
    /// apart, starting at `firstDueAt`.
    ///
    /// Remainder cents land on the earliest payments, so the client is never
    /// surprised by a larger final instalment.
    public func installmentSchedule(
        total: Money,
        count: Int,
        firstDueAt: Date,
        intervalDays: Int = 30,
        calendar: Calendar = .current
    ) -> PaymentSchedule {
        let amount = MoneyMath.clampedToZero(total)
        guard count > 0 else { return PaymentSchedule(total: amount, installments: []) }
        let units = MoneyMath.distribute(MoneyMath.minorUnits(amount.amount), ways: count)
        let step = Swift.max(0, intervalDays)
        let installments = units.enumerated().map { index, value in
            PaymentInstallment(
                id: index,
                kind: .installment,
                label: "Payment \(index + 1) of \(count)",
                amount: MoneyMath.money(value, amount.currency),
                dueAt: firstDueAt.adding(days: index * step, calendar: calendar)
            )
        }
        return PaymentSchedule(total: amount, installments: installments)
    }

    // MARK: Helpers

    /// Wraps allocated minor units in shares carrying payer identity.
    private func shares(from units: [Int], payers: [SplitPayer], currency: Currency) -> [PaymentShare] {
        payers.enumerated().map { index, payer in
            PaymentShare(
                id: index,
                payerID: payer.userID,
                label: payer.name,
                amount: MoneyMath.money(index < units.count ? units[index] : 0, currency)
            )
        }
    }
}
