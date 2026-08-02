import Foundation
import PRVBookingKit
import PRVModels

// The fee/refund arithmetic lives in `PRVBookingKit.CancellationEngine` so the
// figure shown here is exactly the figure the payments layer charges. This
// extension adds only the words around those numbers.
extension CancellationAssessment {
    /// Whole hours until the appointment starts; `0` once it has begun.
    var hoursUntilStart: Int { max(0, minutesUntilStart / 60) }

    /// Headline shown at the top of the cancellation sheet.
    var headline: String {
        switch outcome {
        case .withinFreeWindow: "Free cancellation"
        case .lateCancellation: "Late cancellation"
        case .noShow: "Inside the no-show window"
        case .salonInitiated: "Cancelled by the salon"
        }
    }

    /// SF Symbol matching the outcome's severity.
    var symbolName: String {
        isFree ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    /// One-sentence explanation of what cancelling right now costs.
    /// - Parameter amountPaid: What the client has already paid toward the visit.
    func summary(amountPaid: Money) -> String {
        switch outcome {
        case .salonInitiated:
            return amountPaid.isZero
                ? "The salon cancelled this visit, so nothing is charged."
                : "The salon cancelled this visit — \(refundDue.formatted) is refunded in full."
        case .withinFreeWindow:
            return amountPaid.isZero
                ? "You're inside the free-cancellation window, so nothing is charged."
                : "You're inside the free-cancellation window — \(refundDue.formatted) goes back to you in full."
        case .lateCancellation, .noShow:
            if amountPaid.isZero {
                return "Your appointment \(startPhrase), which is outside the free-cancellation window. Nothing was prepaid, so there's nothing to refund — the salon may still charge its \(feePercent)% fee."
            }
            return "Your appointment \(startPhrase). The salon retains \(fee.formatted) (\(feePercent)%) and \(refundDue.formatted) is refunded to you."
        }
    }

    /// A human fragment describing how imminent the appointment is.
    private var startPhrase: String {
        if minutesUntilStart <= 0 { return "has already started" }
        if minutesUntilStart < 60 { return "starts in \(minutesUntilStart) min" }
        return "starts in \(hoursUntilStart) h"
    }
}
