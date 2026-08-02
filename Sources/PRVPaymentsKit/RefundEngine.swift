import Foundation
import PRVFoundation
import PRVModels

/// What the platform decided to do about a refund request.
///
/// `amount + retainedFee` never exceeds what the client paid, and a decision
/// is either issued by the system (`isAutomatic`), queued for a human
/// (`requiresApproval`), or neither when there is nothing to give back.
public struct RefundDecision: Hashable, Sendable {
    /// The branch of the refund rules that applied.
    public enum Outcome: String, Hashable, Sendable, CaseIterable {
        /// Nothing is owed back — the fee consumed the payment, or nothing
        /// was ever paid.
        case nothingToRefund = "nothing_to_refund"
        /// Issued immediately, no human in the loop.
        case automatic
        /// Queued for a salon manager or the risk team.
        case needsApproval = "needs_approval"
    }

    /// Which branch applied.
    public let outcome: Outcome
    /// What goes back to the client.
    public let amount: Money
    /// What the salon keeps (the cancellation fee, when it survives).
    public let retainedFee: Money
    /// Why the refund was requested.
    public let reason: Refund.Reason
    /// One-line, client-safe explanation for the receipt and the audit log.
    public let explanation: String

    /// Creates a decision.
    public init(
        outcome: Outcome,
        amount: Money,
        retainedFee: Money,
        reason: Refund.Reason,
        explanation: String
    ) {
        self.outcome = outcome
        self.amount = amount
        self.retainedFee = retainedFee
        self.reason = reason
        self.explanation = explanation
    }

    /// Whether the platform issues this refund with no human action — the
    /// value written to `Refund.isAutomatic`.
    public var isAutomatic: Bool { outcome == .automatic }

    /// Whether a manager must approve before any money moves.
    public var requiresApproval: Bool { outcome == .needsApproval }

    /// Whether any money moves at all.
    public var movesMoney: Bool { outcome != .nothingToRefund }
}

/// Applies the platform's automatic-refund rules.
///
/// The engine never reads the clock and never talks to the network: it maps
/// *(amount paid, cancellation fee, reason)* onto a decision, so the same
/// request always resolves the same way on device, on the salon terminal, and
/// in the Edge Function that actually moves the money.
///
/// The matrix, by reason:
///
/// | Reason          | Refunded            | Fee kept | Human |
/// |-----------------|---------------------|----------|-------|
/// | `cancellation`  | paid − fee          | yes      | no    |
/// | `duplicate`     | paid                | no       | no    |
/// | `serviceIssue`  | paid                | no       | yes   |
/// | `goodwill`      | paid − fee          | yes      | yes   |
/// | `fraud`         | paid                | no       | yes   |
///
/// On top of that, any refund above ``Policy/automaticCeiling`` needs a human,
/// however routine the reason — large money always gets a second pair of eyes.
public struct RefundEngine: Sendable {
    /// The salon-configurable half of the rules.
    public struct Policy: Hashable, Sendable {
        /// Refunds at or below this amount can be issued automatically.
        public var automaticCeiling: Money

        /// Creates a policy.
        public init(automaticCeiling: Money = Money(250)) {
            self.automaticCeiling = automaticCeiling
        }

        /// The platform default: automatic up to €250.
        public static let standard = Policy()

        /// Every refund is reviewed by a human.
        public static let alwaysReview = Policy(automaticCeiling: .zero())
    }

    /// The active policy.
    public let policy: Policy

    /// Creates an engine.
    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Decides a refund.
    /// - Parameters:
    ///   - amountPaid: What the client has actually paid on the order.
    ///   - cancellationFee: The fee the salon's policy retains, from
    ///     `PRVBookingKit.CancellationEngine`. Clamped to `amountPaid`.
    ///   - reason: Why the refund was requested.
    public func decide(
        amountPaid: Money,
        cancellationFee: Money,
        reason: Refund.Reason
    ) -> RefundDecision {
        let paid = MoneyMath.clampedToZero(amountPaid)
        let currency = paid.currency
        let fee = MoneyMath.lesser(
            MoneyMath.clampedToZero(MoneyMath.denominated(cancellationFee, in: currency)),
            paid
        )

        let refundable: Money
        let retained: Money
        let needsHuman: Bool
        let explanation: String

        switch reason {
        case .cancellation:
            refundable = MoneyMath.clampedToZero(paid - fee)
            retained = fee
            needsHuman = false
            explanation = fee.isZero
                ? "Cancelled inside the free window — refunded in full."
                : "Cancellation fee of \(fee.formatted) retained under the salon's policy."
        case .duplicate:
            refundable = paid
            retained = .zero(currency)
            needsHuman = false
            explanation = "Duplicate charge — returned in full, no fee applies."
        case .serviceIssue:
            refundable = paid
            retained = .zero(currency)
            needsHuman = true
            explanation = "Service issue reported — the fee is waived pending salon review."
        case .goodwill:
            refundable = MoneyMath.clampedToZero(paid - fee)
            retained = fee
            needsHuman = true
            explanation = "Goodwill refund — requires salon approval."
        case .fraud:
            refundable = paid
            retained = .zero(currency)
            needsHuman = true
            explanation = "Flagged for fraud review — held until the risk team clears it."
        }

        guard !refundable.isZero else {
            return RefundDecision(
                outcome: .nothingToRefund,
                amount: .zero(currency),
                retainedFee: retained,
                reason: reason,
                explanation: paid.isZero
                    ? "Nothing was paid on this order."
                    : "The retained fee covers everything paid — nothing to refund."
            )
        }

        let ceiling = MoneyMath.denominated(policy.automaticCeiling, in: currency)
        let exceedsCeiling = refundable.amount > ceiling.amount

        if needsHuman || exceedsCeiling {
            return RefundDecision(
                outcome: .needsApproval,
                amount: refundable,
                retainedFee: retained,
                reason: reason,
                explanation: exceedsCeiling && !needsHuman
                    ? "Refunds above \(ceiling.formatted) are approved by a manager."
                    : explanation
            )
        }

        return RefundDecision(
            outcome: .automatic,
            amount: refundable,
            retainedFee: retained,
            reason: reason,
            explanation: explanation
        )
    }

    /// Decides a refund for a whole order, using what the order records as
    /// paid.
    public func decide(order: Order, cancellationFee: Money, reason: Refund.Reason) -> RefundDecision {
        decide(amountPaid: order.amountPaid, cancellationFee: cancellationFee, reason: reason)
    }

    /// Materializes a decision as a persistable ``Refund``.
    ///
    /// Returns `nil` when the decision moves no money, so callers can never
    /// post a zero-value refund to the ledger.
    /// - Parameters:
    ///   - orderID: The order being refunded.
    ///   - decision: The decision to record.
    ///   - note: Optional internal note; defaults to the decision's
    ///     explanation so the audit log always reads well.
    ///   - createdAt: Timestamp, injected for determinism.
    public func makeRefund(
        orderID: Order.ID,
        decision: RefundDecision,
        note: String? = nil,
        createdAt: Date = .now
    ) -> Refund? {
        guard decision.movesMoney else { return nil }
        return Refund(
            orderID: orderID,
            amount: decision.amount,
            reason: decision.reason,
            note: note ?? decision.explanation,
            isAutomatic: decision.isAutomatic,
            createdAt: createdAt
        )
    }
}
