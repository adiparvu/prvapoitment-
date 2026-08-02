import SwiftUI
import PRVDesignSystem
import PRVModels

/// Presentation for each notification kind: the human name used in
/// preferences, the one-line explanation beneath it, and the semantic tint of
/// its glass squircle.
///
/// The symbol itself already lives on the model (`kind.symbolName`) — only
/// colour and copy are UI concerns, so only they live here.
extension PRVNotification.Kind {
    /// Human name shown in the preferences list.
    var displayName: String {
        switch self {
        case .appointmentReminder: "Appointment Reminders"
        case .appointmentConfirmed: "Booking Confirmations"
        case .appointmentCancelled: "Cancellations"
        case .waitlistSlotOpened: "Waitlist Openings"
        case .promotion: "Offers & Promotions"
        case .reviewRequest: "Review Requests"
        case .membershipRenewal: "Membership Renewals"
        case .packageExpiring: "Expiring Packages"
        case .priceChange: "Price Changes"
        case .loyaltyReward: "Rewards & Milestones"
        case .chatMessage: "Messages"
        case .system: "Account & Security"
        }
    }

    /// One-line explanation shown beneath the preference toggle.
    var preferenceDetail: String {
        switch self {
        case .appointmentReminder: "A nudge the day before and two hours ahead."
        case .appointmentConfirmed: "When a salon confirms or reschedules your visit."
        case .appointmentCancelled: "If a booking is cancelled by you or the salon."
        case .waitlistSlotOpened: "The moment a slot you're waiting for frees up."
        case .promotion: "Seasonal offers from salons you follow."
        case .reviewRequest: "A gentle ask to rate your visit afterwards."
        case .membershipRenewal: "Before a membership renews or lapses."
        case .packageExpiring: "When unused package sessions are about to expire."
        case .priceChange: "If a service you book regularly changes price."
        case .loyaltyReward: "Tier upgrades, streaks, and points you've earned."
        case .chatMessage: "New messages from your salon or professional."
        case .system: "Sign-ins, receipts, and important account notices."
        }
    }

    /// Semantic tint of the row's glass squircle.
    var tint: Color {
        switch self {
        case .appointmentReminder, .appointmentConfirmed, .chatMessage: Color.prv.accent
        case .appointmentCancelled: Color.prv.danger
        case .waitlistSlotOpened: Color.prv.success
        case .promotion, .packageExpiring, .priceChange: Color.prv.warning
        case .reviewRequest, .membershipRenewal, .loyaltyReward: Color.prv.gold
        case .system: Color.prv.textSecondary
        }
    }

    /// Kinds the user may silence. Account and security notices are always
    /// delivered, matching how the rest of the platform treats critical mail.
    static var configurableCases: [PRVNotification.Kind] {
        allCases.filter { $0 != .system }
    }
}
