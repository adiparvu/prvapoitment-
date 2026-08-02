import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVLoyaltyKit
import PRVModels
import PRVNetworking

// MARK: - Load phase

/// Lifecycle of a wallet/loyalty screen's initial load.
///
/// One phase per screen rather than per section: the wallet is a single financial
/// statement, and showing half a balance is worse than showing a skeleton.
enum WalletPhase: Equatable, Sendable {
    /// Fetching — render skeletons.
    case loading
    /// Content is ready.
    case loaded
    /// The fetch failed, with warm, actionable copy.
    case failed(String)

    var isLoading: Bool { self == .loading }
}

// MARK: - Formatting

/// Shared, deterministic display formatting for the wallet and loyalty screens.
/// Pure helpers only — no state, no side effects.
enum WalletFormatting {
    /// Maps transport errors to warm, actionable copy — never raw codes.
    /// `subject` names what failed, e.g. `"Your wallet"`.
    static func friendlyError(_ error: any Error, subject: String) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        switch apiError {
        case .offline, .network:
            return "You appear to be offline. Check your connection and pull to refresh."
        case .notFound:
            return "\(subject) is not available right now."
        case .rateLimited:
            return "Too many requests. Take a breath and try again in a moment."
        case .unauthorized, .forbidden:
            return "Please sign in again to see this."
        case .conflict, .server, .decoding:
            return "Our servers are momentarily busy. Please try again shortly."
        }
    }

    /// A signed money string: credits gain a `+`, debits keep their own `−`.
    static func signed(_ money: Money) -> String {
        money.amount > 0 ? "+\(money.formatted)" : money.formatted
    }

    /// Semantic colour for a signed movement: money in is success, money out danger,
    /// a zero movement stays neutral so it never shouts.
    static func signedTint(_ money: Money) -> Color {
        if money.amount > 0 { return Color.prv.success }
        if money.amount < 0 { return Color.prv.danger }
        return Color.prv.textSecondary
    }

    /// Points with grouping separators, e.g. `1,240`.
    static func points(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// "Ends in 3 days" / "Ends tomorrow" / "Ends today" / "Ended".
    static func endsIn(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if date <= now { return "Ended" }
        switch days {
        case ..<0: return "Ended"
        case 0: return "Ends today"
        case 1: return "Ends tomorrow"
        case 2 ... 30: return "Ends in \(days) days"
        default: return "Ends \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    /// A gift card's masked code, e.g. `"GIFT-••••-K7M2"`, safe to show on screen.
    static func maskedCode(_ code: String) -> String {
        guard code.count > 4 else { return code }
        return "•••• " + String(code.suffix(4))
    }
}

// MARK: - Transaction presentation

extension WalletTransaction.Kind {
    /// Human label for a ledger row.
    var walletDisplayName: String {
        switch self {
        case .payment: "Payment"
        case .refund: "Refund"
        case .cashback: "Cashback"
        case .storeCreditTopUp: "Top-up"
        case .storeCreditSpend: "Store credit used"
        case .giftCardRedemption: "Gift card"
        case .rewardPoints: "Reward points"
        }
    }

    /// SF Symbol for the ledger row's icon tile.
    var walletSymbolName: String {
        switch self {
        case .payment: "creditcard.fill"
        case .refund: "arrow.uturn.backward.circle.fill"
        case .cashback: "arrow.down.circle.fill"
        case .storeCreditTopUp: "plus.circle.fill"
        case .storeCreditSpend: "minus.circle.fill"
        case .giftCardRedemption: "giftcard.fill"
        case .rewardPoints: "sparkles"
        }
    }
}

// MARK: - Month grouping

/// One month of wallet movements, newest month first.
struct TransactionMonth: Identifiable, Hashable, Sendable {
    /// Start of the month, which also identifies the section.
    let id: Date
    /// The month's movements, newest first.
    let transactions: [WalletTransaction]

    /// Section title, e.g. "March 2026".
    var title: String {
        id.formatted(.dateTime.month(.wide).year())
    }

    /// Net movement for the month. Only same-currency rows are summed — a mixed
    /// ledger reports the dominant currency rather than asserting.
    var net: Money {
        guard let currency = transactions.first?.amount.currency else { return .zero() }
        return transactions
            .filter { $0.amount.currency == currency }
            .reduce(Money.zero(currency)) { $0 + $1.amount }
    }
}

// MARK: - Gift card codes

/// Mints client-facing gift-card codes.
///
/// Reuses ``ReferralEngine/alphabet`` — the unambiguous 32-character set with no
/// `I`, `O`, `0`, or `1` — so a code read aloud over the phone or copied off a
/// printed card can never be mistyped into a different valid code.
enum GiftCardCodeFactory {
    /// A fresh code in `GIFT-XXXX-XXXX` form.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    /// A fresh code from an explicit generator, for previews and tests.
    static func make<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        let alphabet = ReferralEngine.alphabet
        var body = ""
        body.reserveCapacity(8)
        for _ in 0 ..< 8 {
            body.append(alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)])
        }
        return "GIFT-\(body.prefix(4))-\(body.suffix(4))"
    }
}

// MARK: - Tier styling

/// Tier-specific visual treatment for the loyalty hero.
///
/// Every colour is composed from design-system tokens — the gold tiers lean on
/// `Color.prv.gold`, Black borrows the primary text colour for its lacquered
/// treatment — so the styling still follows Dark Mode and high-contrast settings.
struct LoyaltyTierStyle {
    /// Emblem gradient behind the tier ring.
    let gradient: LinearGradient
    /// Ring stroke style.
    let ringTint: LinearGradient
    /// SF Symbol for the tier emblem.
    let symbolName: String
    /// Foreground colour that reads on ``gradient``.
    let onGradient: Color
    /// Short, aspirational description of the tier's standing.
    let tagline: String

    /// The treatment for a tier.
    static func style(for tier: LoyaltyTier) -> LoyaltyTierStyle {
        switch tier {
        case .bronze:
            return LoyaltyTierStyle(
                gradient: gradient(Color.prv.accentSecondary, Color.prv.gold),
                ringTint: gradient(Color.prv.accentSecondary, Color.prv.gold),
                symbolName: "sparkle",
                onGradient: Color.prv.textOnAccent,
                tagline: "Your journey starts here"
            )
        case .silver:
            return LoyaltyTierStyle(
                gradient: gradient(Color.prv.textSecondary, Color.prv.separator),
                ringTint: gradient(Color.prv.textSecondary, Color.prv.separator),
                symbolName: "star.fill",
                onGradient: Color.prv.textOnAccent,
                tagline: "Early access to new services"
            )
        case .gold:
            return LoyaltyTierStyle(
                gradient: gradient(Color.prv.gold, Color.prv.accentSecondary),
                ringTint: gradient(Color.prv.gold, Color.prv.accentSecondary),
                symbolName: "crown.fill",
                onGradient: Color.prv.textOnAccent,
                tagline: "Priority booking and exclusive offers"
            )
        case .diamond:
            return LoyaltyTierStyle(
                gradient: gradient(Color.prv.accent, Color.prv.accentSecondary),
                ringTint: gradient(Color.prv.accent, Color.prv.accentSecondary),
                symbolName: "diamond.fill",
                onGradient: Color.prv.textOnAccent,
                tagline: "Concierge booking and partner perks"
            )
        case .black:
            return LoyaltyTierStyle(
                gradient: gradient(Color.prv.textPrimary, Color.prv.textPrimary.opacity(0.72)),
                ringTint: gradient(Color.prv.gold, Color.prv.accentSecondary),
                symbolName: "seal.fill",
                onGradient: Color.prv.gold,
                tagline: "Everything, without asking"
            )
        }
    }

    private static func gradient(_ start: Color, _ end: Color) -> LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
