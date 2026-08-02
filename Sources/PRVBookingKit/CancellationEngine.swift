import Foundation
import PRVModels

/// The outcome of applying a salon's cancellation policy to one appointment.
///
/// Money is exact `Decimal` arithmetic end to end: `fee + refundDue` always equals
/// the amount paid, so the figure shown in the UI is the figure the payments layer
/// charges.
public struct CancellationAssessment: Hashable, Sendable {
    /// Which branch of the policy applied.
    public enum Outcome: String, Hashable, Sendable, CaseIterable {
        /// Cancelled early enough to be free of charge.
        case withinFreeWindow = "within_free_window"
        /// Cancelled inside the free-cancellation window.
        case lateCancellation = "late_cancellation"
        /// The client never arrived, or cancelled after the appointment began.
        case noShow = "no_show"
        /// The salon cancelled — never chargeable to the client.
        case salonInitiated = "salon_initiated"
    }

    /// The branch of the policy that applied.
    public let outcome: Outcome
    /// Fee as a percentage of the amount paid, clamped to `0...100`.
    public let feePercent: Int
    /// The amount the salon keeps.
    public let fee: Money
    /// The amount returned to the client.
    public let refundDue: Money
    /// `true` when the policy charges nothing, whatever was paid.
    public let isFree: Bool
    /// Whole minutes between "now" and the appointment start; negative once it has begun.
    public let minutesUntilStart: Int

    /// Creates an assessment. `isFree` is derived from `feePercent`.
    public init(
        outcome: Outcome,
        feePercent: Int,
        fee: Money,
        refundDue: Money,
        minutesUntilStart: Int
    ) {
        self.outcome = outcome
        self.feePercent = feePercent
        self.fee = fee
        self.refundDue = refundDue
        self.isFree = feePercent == 0
        self.minutesUntilStart = minutesUntilStart
    }
}

/// Applies `SalonPolicies` to a cancellation or no-show and produces the exact fee
/// and refund.
///
/// Deterministic by construction: "now" is always passed in, never read from the
/// system clock, so the same inputs always produce the same money.
public struct CancellationEngine: Sendable {
    /// What caused the appointment to end early.
    public enum Trigger: String, Hashable, Sendable, CaseIterable {
        /// The client cancelled; the free-window rule decides the fee.
        case clientCancellation = "client_cancellation"
        /// The client did not arrive; `noShowFeePercent` applies.
        case noShow = "no_show"
        /// The salon cancelled; never chargeable.
        case salonCancellation = "salon_cancellation"
    }

    /// Calendar injected for symmetry with the rest of the kit.
    public let calendar: Calendar

    /// Creates an engine.
    public init(calendar: Calendar = .prvBooking) {
        self.calendar = calendar
    }

    /// Assesses a cancellation.
    ///
    /// Policy resolution, in order:
    /// 1. A salon-initiated cancellation is always free and fully refunded.
    /// 2. A no-show charges `noShowFeePercent`.
    /// 3. A client cancellation at or after the appointment start is treated as a
    ///    no-show — the chair was held and lost.
    /// 4. A client cancellation at least `freeCancellationHours` before the start is
    ///    free. The boundary itself is inclusive: cancelling exactly 24 hours before
    ///    a 24-hour policy costs nothing.
    /// 5. Otherwise `lateCancellationFeePercent` applies.
    ///
    /// - Parameters:
    ///   - policies: the salon's published policy.
    ///   - appointmentStart: when the visit was due to begin.
    ///   - now: the instant of the cancellation.
    ///   - amountPaid: what the client has already paid — deposit or full prepayment.
    ///   - trigger: what caused the cancellation.
    public func assess(
        policies: SalonPolicies,
        appointmentStart: Date,
        now: Date,
        amountPaid: Money,
        trigger: Trigger = .clientCancellation
    ) -> CancellationAssessment {
        let secondsUntilStart = appointmentStart.timeIntervalSince(now)
        let minutesUntilStart = Int((secondsUntilStart / 60).rounded(.towardZero))

        let outcome: CancellationAssessment.Outcome
        let requestedPercent: Int

        switch trigger {
        case .salonCancellation:
            outcome = .salonInitiated
            requestedPercent = 0
        case .noShow:
            outcome = .noShow
            requestedPercent = policies.noShowFeePercent
        case .clientCancellation:
            let freeWindow = TimeInterval(max(0, policies.freeCancellationHours) * 3_600)
            if secondsUntilStart <= 0 {
                outcome = .noShow
                requestedPercent = policies.noShowFeePercent
            } else if secondsUntilStart >= freeWindow {
                outcome = .withinFreeWindow
                requestedPercent = 0
            } else {
                outcome = .lateCancellation
                requestedPercent = policies.lateCancellationFeePercent
            }
        }

        let feePercent = min(100, max(0, requestedPercent))
        let chargeable = max(amountPaid, Money(0, amountPaid.currency))
        let fee = min(chargeable.percentage(Decimal(feePercent)), chargeable)
        let refund = chargeable - fee

        return CancellationAssessment(
            outcome: outcome,
            feePercent: feePercent,
            fee: fee,
            refundDue: refund,
            minutesUntilStart: minutesUntilStart
        )
    }

    /// Convenience overload taking the appointment itself.
    ///
    /// Returns `nil` when the appointment has no items and therefore no start.
    public func assess(
        policies: SalonPolicies,
        appointment: Appointment,
        now: Date,
        amountPaid: Money,
        trigger: Trigger = .clientCancellation
    ) -> CancellationAssessment? {
        guard let start = appointment.start else { return nil }
        return assess(
            policies: policies,
            appointmentStart: start,
            now: now,
            amountPaid: amountPaid,
            trigger: trigger
        )
    }

    /// The last instant at which cancelling this appointment is still free.
    public func freeCancellationDeadline(
        policies: SalonPolicies,
        appointmentStart: Date
    ) -> Date {
        appointmentStart.addingTimeInterval(-TimeInterval(max(0, policies.freeCancellationHours) * 3_600))
    }

    /// `true` when a client cancelling at `now` would pay nothing.
    public func isWithinFreeWindow(
        policies: SalonPolicies,
        appointmentStart: Date,
        now: Date
    ) -> Bool {
        now <= freeCancellationDeadline(policies: policies, appointmentStart: appointmentStart)
    }

    /// The instant after which a late client counts as a no-show.
    public func noShowThreshold(policies: SalonPolicies, appointmentStart: Date) -> Date {
        appointmentStart.addingTimeInterval(TimeInterval(max(0, policies.lateGraceMinutes) * 60))
    }
}
