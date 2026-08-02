import Foundation
import PRVFoundation
import PRVModels

/// What cancelling an appointment costs the client right now: whether the
/// free window still applies, the fee the salon retains, and what returns to
/// the client's card or wallet.
struct CancellationAssessment: Hashable, Sendable {
    /// Whether the cancellation falls inside the salon's free window.
    var isFree: Bool
    /// Whole hours remaining before the appointment starts (0 once it has begun).
    var hoursUntilStart: Int
    /// Percentage of the appointment total the salon retains (0–100).
    var feePercent: Int
    /// Monetary fee retained by the salon.
    var fee: Money
    /// Amount returned to the client from what they already paid.
    var refund: Money
    /// Amount the client already paid toward the appointment.
    var amountPaid: Money
    /// The appointment total the fee is calculated from.
    var total: Money

    /// Headline shown at the top of the cancellation sheet.
    var headline: String {
        isFree ? "Free cancellation" : "Late cancellation"
    }

    /// One-sentence explanation of the outcome.
    var summary: String {
        if isFree {
            return amountPaid.isZero
                ? "You're inside the free-cancellation window, so nothing is charged."
                : "You're inside the free-cancellation window — \(refund.formatted) goes back to you in full."
        }
        if amountPaid.isZero {
            return "Your appointment starts \(hoursUntilStart == 0 ? "very soon" : "in \(hoursUntilStart) h"), so the salon charges a \(feePercent)% late-cancellation fee of \(fee.formatted)."
        }
        return "Your appointment starts \(hoursUntilStart == 0 ? "very soon" : "in \(hoursUntilStart) h"). The salon retains \(fee.formatted) (\(feePercent)%) and \(refund.formatted) is refunded to you."
    }
}

/// Applies a salon's cancellation policy to a specific appointment.
///
/// - Note: This mirrors the rules that belong in `PRVBookingKit`'s
///   cancellation engine. The kit is not on disk yet, so the feature assesses
///   cancellations locally; replace this with the kit's engine once it lands
///   so client-side previews and server-side enforcement cannot drift.
enum CancellationAssessor {
    /// Assesses cancelling `appointment` at `now`.
    /// - Parameters:
    ///   - appointment: The appointment being cancelled.
    ///   - policies: The salon's policies.
    ///   - amountPaid: What the client has already paid (order `amountPaid`).
    ///   - now: Evaluation time. Defaults to the current instant.
    static func assess(
        appointment: Appointment,
        policies: SalonPolicies,
        amountPaid: Money,
        now: Date = .now
    ) -> CancellationAssessment {
        let total = appointment.totalPrice
        let start = appointment.start ?? now
        let secondsUntilStart = max(0, start.timeIntervalSince(now))
        let hoursUntilStart = Int(secondsUntilStart / 3_600)
        let isFree = secondsUntilStart >= TimeInterval(policies.freeCancellationHours) * 3_600

        let feePercent = isFree ? 0 : max(0, min(100, policies.lateCancellationFeePercent))
        let rawFee = feePercent > 0 ? total.percentage(Decimal(feePercent)) : Money.zero(total.currency)
        // The client can never be refunded more than they paid, and the fee
        // charged against a refund can never exceed it either.
        let paid = Money(amountPaid.amount, total.currency)
        let refundValue = paid - rawFee
        let refund = refundValue.amount < 0 ? Money.zero(total.currency) : refundValue

        return CancellationAssessment(
            isFree: isFree,
            hoursUntilStart: hoursUntilStart,
            feePercent: feePercent,
            fee: rawFee,
            refund: refund,
            amountPaid: paid,
            total: total
        )
    }
}
