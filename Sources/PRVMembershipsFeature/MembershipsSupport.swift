import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Load phase

/// Lifecycle of a memberships-family screen's initial load.
///
/// One phase per screen rather than per section: memberships, packages, and
/// gift cards are each a single commercial offer, and showing half a price
/// list is worse than showing a skeleton — a price on screen is a promise.
enum MembershipsPhase: Equatable, Sendable {
    /// Fetching — render skeletons.
    case loading
    /// Content is ready.
    case loaded
    /// The fetch failed, with warm, actionable copy.
    case failed(String)

    /// Whether the screen is still performing its first load.
    var isLoading: Bool { self == .loading }
}

// MARK: - Formatting

/// Shared, deterministic display formatting for the memberships, packages,
/// and gift-card screens. Pure helpers only — no state, no side effects, so
/// every string on screen is reproducible in a test.
enum MembershipsFormatting {
    /// Maps transport errors to warm, actionable copy — never raw codes.
    /// `subject` names what failed, e.g. `"Memberships"`.
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
            return "Please sign in again to continue."
        case .conflict, .server, .decoding:
            return "Our servers are momentarily busy. Please try again shortly."
        }
    }

    /// The unit a plan is billed in: "month", "quarter", or "year".
    static func cycleUnit(_ cycle: BillingCycle) -> String {
        switch cycle {
        case .monthly: "month"
        case .quarterly: "quarter"
        case .yearly: "year"
        }
    }

    /// A plan price with its cycle, e.g. `"€89.00 / month"`.
    static func pricePerCycle(_ price: Money, cycle: BillingCycle) -> String {
        "\(price.formatted) / \(cycleUnit(cycle))"
    }

    /// What a non-monthly plan works out to per month, so quarterly and
    /// yearly plans can be compared against monthly ones at a glance.
    static func monthlyEquivalent(_ price: Money, cycle: BillingCycle) -> Money {
        guard cycle.months > 1 else { return price }
        return Money((price.amount / Decimal(cycle.months)).rounded(), price.currency)
    }

    /// "Renews today" / "Renews tomorrow" / "Renews in 12 days" /
    /// "Renews 14 Mar 2027" — the closer the date, the more precise the copy.
    static func renewal(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        if date <= now { return "Renewal overdue" }
        switch days {
        case ..<0: return "Renewal overdue"
        case 0: return "Renews today"
        case 1: return "Renews tomorrow"
        case 2 ... 30: return "Renews in \(days) days"
        default: return "Renews \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    /// "Benefits stay yours until 14 Mar 2027" — shown after a cancellation
    /// so nobody thinks they lost what they already paid for.
    static func benefitsUntil(_ date: Date) -> String {
        "Benefits stay yours until \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    /// How long a package buyer has to redeem everything inside it.
    /// Rounds to months once the window is long enough to read that way.
    static func validity(_ days: Int) -> String {
        switch days {
        case ..<1: return "Redeem on the day of purchase"
        case 1: return "Redeem within 1 day"
        case 2 ... 45: return "Redeem within \(days) days"
        case 46 ... 364:
            let months = Int((Double(days) / 30.0).rounded())
            return "Redeem within \(months) months"
        default:
            let years = max(1, Int((Double(days) / 365.0).rounded()))
            return years == 1 ? "Redeem within 1 year" : "Redeem within \(years) years"
        }
    }

    /// A package's discount as a whole percentage, or `nil` when there is
    /// nothing to boast about.
    static func savingsPercent(_ package: ServicePackage) -> Int? {
        let regular = package.regularPrice.amount
        let saved = package.savings.amount
        guard regular > 0, saved > 0 else { return nil }
        let percent = (saved / regular * 100).rounded(scale: 0)
        let whole = NSDecimalNumber(decimal: percent).intValue
        return whole > 0 ? whole : nil
    }

    /// A gift card's masked code, e.g. `"•••• K7M2"`, safe to show on screen
    /// before the owner deliberately reveals it.
    static func maskedCode(_ code: String) -> String {
        guard code.count > 4 else { return code }
        return "•••• " + String(code.suffix(4))
    }

    /// Value badge text for a benefit, e.g. `"15%"` for a discount or
    /// `"2×"` for repeated free services. `nil` when a checkmark says it all.
    static func benefitValue(kind: MembershipBenefit.Kind, value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        switch kind {
        case .discountPercent: return "\(value)%"
        case .freeService: return "\(value)×"
        case .priorityBooking, .birthdayGift, .exclusiveEvents, .partnerBenefit: return nil
        }
    }

    /// Duration copy for an included service, e.g. `"2 h 30 min"`.
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return "\(hours) h" }
        return "\(hours) h \(remainder) min"
    }
}

// MARK: - Tier styling

/// Tier-specific visual treatment for membership cards.
///
/// Every colour is composed from design-system tokens — the precious tiers
/// lean on `Color.prv.gold` and the brand accent, Silver and Black use
/// monochrome ramps built from the semantic text colours — so the treatment
/// keeps following Dark Mode, Increase Contrast, and Smart Invert.
struct MembershipTierStyle: Sendable {
    /// Display name for the tier ("Gold").
    let title: String
    /// SF Symbol used as the tier emblem.
    let symbolName: String
    /// One short, aspirational line describing the tier's standing.
    let tagline: String
    /// Gradient ramp behind the emblem and card header.
    let colors: [Color]
    /// Foreground colour guaranteed to read on ``gradient``.
    let onGradient: Color
    /// Ordering weight — Silver is entry level, Black is the summit.
    let rank: Int

    /// The tier gradient, always running top-leading to bottom-trailing so
    /// stacked cards catch the light consistently.
    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A single tier colour for benefit icons and accents that sit on glass
    /// rather than on the gradient.
    var accentTint: Color { colors.first ?? Color.prv.accent }

    /// The treatment for a tier.
    static func style(for tier: MembershipTier) -> MembershipTierStyle {
        switch tier {
        case .silver:
            // Monochrome: a brushed-metal ramp from the secondary text colour.
            MembershipTierStyle(
                title: tier.displayName,
                symbolName: "star.fill",
                tagline: "The essentials, every month",
                colors: [Color.prv.textSecondary, Color.prv.textSecondary.opacity(0.5)],
                onGradient: Color.prv.textOnAccent,
                rank: 1
            )
        case .gold:
            MembershipTierStyle(
                title: tier.displayName,
                symbolName: "crown.fill",
                tagline: "Priority booking and standing discounts",
                colors: [Color.prv.gold, Color.prv.accentSecondary],
                onGradient: Color.prv.textOnAccent,
                rank: 2
            )
        case .diamond:
            MembershipTierStyle(
                title: tier.displayName,
                symbolName: "diamond.fill",
                tagline: "Concierge booking and partner perks",
                colors: [Color.prv.accent, Color.prv.accentSecondary],
                onGradient: Color.prv.textOnAccent,
                rank: 3
            )
        case .black:
            // Monochrome lacquer: the primary text colour with gold type on
            // top, so it inverts elegantly in Dark Mode instead of vanishing.
            MembershipTierStyle(
                title: tier.displayName,
                symbolName: "seal.fill",
                tagline: "Everything, without asking",
                colors: [Color.prv.textPrimary, Color.prv.textPrimary.opacity(0.72)],
                onGradient: Color.prv.gold,
                rank: 4
            )
        case .custom:
            MembershipTierStyle(
                title: tier.displayName,
                symbolName: "wand.and.stars",
                tagline: "Tailored to this salon",
                colors: [Color.prv.accentSecondary, Color.prv.gold],
                onGradient: Color.prv.textOnAccent,
                rank: 5
            )
        }
    }
}

extension MembershipTier {
    /// Ordering weight used to sort tiers from entry level to summit.
    var membershipRank: Int { MembershipTierStyle.style(for: self).rank }
}

// MARK: - Benefit styling

extension MembershipBenefit.Kind {
    /// Human label for a benefit category, used as the comparison-table row
    /// title. Individual benefits carry their own richer `title`.
    var membershipDisplayName: String {
        switch self {
        case .freeService: "Free services"
        case .discountPercent: "Member discount"
        case .priorityBooking: "Priority booking"
        case .birthdayGift: "Birthday gift"
        case .exclusiveEvents: "Exclusive events"
        case .partnerBenefit: "Partner perks"
        }
    }

    /// SF Symbol shown beside the benefit.
    var membershipSymbolName: String {
        switch self {
        case .freeService: "gift.fill"
        case .discountPercent: "percent"
        case .priorityBooking: "bolt.fill"
        case .birthdayGift: "birthday.cake.fill"
        case .exclusiveEvents: "ticket.fill"
        case .partnerBenefit: "sparkles"
        }
    }

    /// Canonical order for benefit rows, most concrete value first.
    static var membershipDisplayOrder: [MembershipBenefit.Kind] {
        [.freeService, .discountPercent, .priorityBooking, .birthdayGift, .exclusiveEvents, .partnerBenefit]
    }
}

// MARK: - Subscription status styling

extension MembershipSubscription.Status {
    /// Human label for the status badge.
    var membershipDisplayName: String {
        switch self {
        case .active: "Active"
        case .pastDue: "Payment due"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }

    /// Semantic badge tint.
    var membershipTint: Color {
        switch self {
        case .active: Color.prv.success
        case .pastDue: Color.prv.warning
        case .cancelled, .expired: Color.prv.textSecondary
        }
    }

    /// Whether the membership still entitles the client to benefits — and
    /// can therefore still be cancelled.
    var membershipIsLive: Bool {
        switch self {
        case .active, .pastDue: true
        case .cancelled, .expired: false
        }
    }
}

// MARK: - Billing cycle filter

/// Billing-cycle filter backing the plan grid's segmented picker.
enum PlanCycleFilter: Hashable, Sendable {
    /// Every plan, whatever its cycle.
    case all
    /// Only plans billed on this cycle.
    case cycle(BillingCycle)

    /// Segment label.
    var title: String {
        switch self {
        case .all: "All"
        case .cycle(let cycle): cycle.displayName
        }
    }

    /// Whether a plan on `cycle` passes this filter.
    func matches(_ cycle: BillingCycle) -> Bool {
        switch self {
        case .all: true
        case .cycle(let selected): selected == cycle
        }
    }
}

// MARK: - Package theme styling

/// Theme-specific treatment for package cards: a symbol header on a gradient
/// glass wash, composed entirely from design-system tokens.
struct PackageThemeStyle: Sendable {
    /// Display name for the theme ("Bridal").
    let title: String
    /// SF Symbol for the card's header medallion.
    let symbolName: String
    /// One line of context under the theme name.
    let tagline: String
    /// Gradient ramp for the header wash.
    let colors: [Color]

    /// The header gradient.
    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A single theme colour for accents that sit on glass.
    var accentTint: Color { colors.first ?? Color.prv.accent }

    /// The treatment for a package theme.
    static func style(for theme: ServicePackage.Theme) -> PackageThemeStyle {
        switch theme {
        case .wedding:
            PackageThemeStyle(
                title: "Bridal",
                symbolName: "heart.fill",
                tagline: "Trial, rehearsal, and the day itself",
                colors: [Color.prv.accent, Color.prv.accentSecondary]
            )
        case .holiday:
            PackageThemeStyle(
                title: "Holiday",
                symbolName: "gift.fill",
                tagline: "Ready for every celebration",
                colors: [Color.prv.gold, Color.prv.accent]
            )
        case .seasonal:
            PackageThemeStyle(
                title: "Seasonal",
                symbolName: "leaf.fill",
                tagline: "A refresh for the new season",
                colors: [Color.prv.success, Color.prv.gold]
            )
        case .monthly:
            PackageThemeStyle(
                title: "Monthly",
                symbolName: "calendar",
                tagline: "Your routine, prepaid",
                colors: [Color.prv.accent, Color.prv.gold]
            )
        case .luxurySpa:
            PackageThemeStyle(
                title: "Luxury Spa",
                symbolName: "sparkles",
                tagline: "An unhurried afternoon",
                colors: [Color.prv.accentSecondary, Color.prv.gold]
            )
        case .combo:
            PackageThemeStyle(
                title: "Combo",
                symbolName: "square.stack.3d.up.fill",
                tagline: "Favourites, bundled",
                colors: [Color.prv.accent, Color.prv.textSecondary]
            )
        case .custom:
            PackageThemeStyle(
                title: "Signature",
                symbolName: "wand.and.stars",
                tagline: "Built by this salon",
                colors: [Color.prv.accentSecondary, Color.prv.accent]
            )
        }
    }
}

// MARK: - Tier comparison

/// A tier-by-benefit comparison matrix, built once in the screen model so the
/// table never does set arithmetic inside `body`.
struct TierComparisonMatrix: Equatable, Sendable {
    /// One benefit row of the comparison table.
    struct Row: Identifiable, Equatable, Sendable {
        /// What a tier offers for this benefit.
        enum Cell: Equatable, Sendable {
            /// The tier does not include this benefit.
            case absent
            /// Included, with nothing to quantify.
            case included
            /// Included, with a headline figure ("15%", "2×").
            case value(String)

            /// Whether the tier includes the benefit at all.
            var isIncluded: Bool { self != .absent }
        }

        /// The benefit category this row compares.
        let kind: MembershipBenefit.Kind
        /// One cell per tier, keyed by tier.
        let cells: [MembershipTier: Cell]

        var id: MembershipBenefit.Kind { kind }

        /// The cell for a tier, defaulting to "not included".
        func cell(for tier: MembershipTier) -> Cell { cells[tier] ?? .absent }
    }

    /// Table columns, entry tier first.
    let tiers: [MembershipTier]
    /// Table rows, in canonical benefit order.
    let rows: [Row]

    /// Nothing worth rendering.
    var isEmpty: Bool { tiers.isEmpty || rows.isEmpty }

    /// A table with more than one column genuinely compares; a single-column
    /// table simply lists what is included.
    var isComparison: Bool { tiers.count > 1 }

    /// The empty matrix.
    static let empty = TierComparisonMatrix(tiers: [], rows: [])

    /// Builds the matrix from the plans a salon (or the platform) sells.
    ///
    /// Columns are the tiers actually on sale, ordered entry-level first.
    /// Rows are the benefit categories at least one plan offers, so the table
    /// never advertises an empty column of dashes. Where several plans share
    /// a tier, the most generous figure wins — that is the promise the tier
    /// makes.
    static func build(from plans: [MembershipPlan]) -> TierComparisonMatrix {
        guard !plans.isEmpty else { return .empty }

        let tiers = Set(plans.map(\.tier)).sorted { $0.membershipRank < $1.membershipRank }

        // Which kinds each tier offers, and the most generous figure stated
        // for them — a bigger number is the promise the tier actually makes.
        var offered: [MembershipTier: Set<MembershipBenefit.Kind>] = [:]
        var figures: [MembershipTier: [MembershipBenefit.Kind: Int]] = [:]
        for plan in plans {
            for benefit in plan.benefits {
                offered[plan.tier, default: []].insert(benefit.kind)
                if let value = benefit.value, value > 0 {
                    let current = figures[plan.tier]?[benefit.kind] ?? 0
                    figures[plan.tier, default: [:]][benefit.kind] = max(current, value)
                }
            }
        }

        let rows = MembershipBenefit.Kind.membershipDisplayOrder.compactMap { kind -> Row? in
            var cells: [MembershipTier: Row.Cell] = [:]
            for tier in tiers where offered[tier]?.contains(kind) == true {
                if let figure = figures[tier]?[kind],
                   let text = MembershipsFormatting.benefitValue(kind: kind, value: figure) {
                    cells[tier] = .value(text)
                } else {
                    cells[tier] = .included
                }
            }
            return cells.isEmpty ? nil : Row(kind: kind, cells: cells)
        }

        return TierComparisonMatrix(tiers: tiers, rows: rows)
    }
}

// MARK: - Gift card codes

/// Mints client-facing gift-card codes.
///
/// The alphabet deliberately omits `I`, `O`, `0`, and `1`: a code read aloud
/// over the phone or copied off a printed card can never be mistyped into a
/// *different valid code*, which is the only mistake that actually costs
/// someone money.
enum GiftCardCodeFactory {
    /// The 32-character unambiguous alphabet.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// A fresh code in `GIFT-XXXX-XXXX` form.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    /// A fresh code from an explicit generator, for previews and tests.
    static func make<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        var body = ""
        body.reserveCapacity(8)
        for _ in 0 ..< 8 {
            body.append(alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)])
        }
        return "GIFT-\(body.prefix(4))-\(body.suffix(4))"
    }
}

// MARK: - Gift card validation

/// Validation rules for the gift-card designer, kept pure so the CTA's
/// enabled state and the inline hint can never disagree.
enum GiftCardRules {
    /// Smallest amount a gift card may carry.
    static let minimumAmount: Decimal = 5
    /// Largest amount a single card may carry, matching the payment
    /// processor's per-transaction ceiling.
    static let maximumAmount: Decimal = 1_000
    /// Preset amounts offered before anyone reaches for the keyboard.
    static let presets: [Decimal] = [25, 50, 100, 150, 250]
    /// How long a purchased card stays redeemable.
    static let validityYears = 2

    /// Why an amount cannot be bought, or `nil` when it can.
    static func amountProblem(_ amount: Decimal) -> String? {
        if amount < minimumAmount {
            return "Minimum \(Money(minimumAmount).formatted)."
        }
        if amount > maximumAmount {
            return "Maximum \(Money(maximumAmount).formatted) per card."
        }
        return nil
    }

    /// Whether a recipient address looks deliverable. Empty is valid — a card
    /// with no recipient simply stays in the buyer's own wallet.
    static func isRecipientAcceptable(_ email: String) -> Bool {
        let trimmed = email.trimmed
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains(" "), trimmed.count >= 6 else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// Longest gift message we render on the card preview.
    static let messageLimit = 180
}
