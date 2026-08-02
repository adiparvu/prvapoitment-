import Foundation
import Observation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Rules

/// Constants the marketing desk works to. Kept outside the model so views and
/// the suggestion engine can read them without hopping actors.
enum MarketingRules {
    /// How far back the suggestion engine looks.
    static let insightWindowDays = 30
    /// Retention below this fraction triggers the win-back suggestion.
    static let retentionThreshold = 0.85
}

// MARK: - Tabs

/// The two halves of the Marketing desk.
enum MarketingTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case campaigns
    case coupons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .campaigns: "Campaigns"
        case .coupons: "Coupons"
        }
    }
}

// MARK: - Campaign draft

/// The editable shape of a campaign, used by the composer sheet and by the
/// suggestion cards that prefill it.
struct CampaignDraft: Identifiable, Hashable, Sendable {
    /// The campaign being edited, when this is an edit rather than a new one.
    var original: Campaign?
    var name: String
    var kind: Campaign.Kind
    var channels: [Campaign.Channel]
    var message: String
    var couponID: Coupon.ID?
    var isScheduled: Bool
    var scheduledAt: Date

    /// Stable identity for `sheet(item:)`; a new draft gets a fresh token so
    /// prefilling from two different suggestions re-presents the sheet.
    let id: String

    init(
        original: Campaign? = nil,
        name: String = "",
        kind: Campaign.Kind = .promotion,
        channels: [Campaign.Channel] = [.push],
        message: String = "",
        couponID: Coupon.ID? = nil,
        isScheduled: Bool = false,
        scheduledAt: Date = Date.now.adding(days: 1),
        id: String = UUID().uuidString
    ) {
        self.original = original
        self.name = name
        self.kind = kind
        self.channels = channels
        self.message = message
        self.couponID = couponID
        self.isScheduled = isScheduled
        self.scheduledAt = scheduledAt
        self.id = id
    }

    /// Creates a draft that edits an existing campaign.
    static func editing(_ campaign: Campaign) -> CampaignDraft {
        CampaignDraft(
            original: campaign,
            name: campaign.name,
            kind: campaign.kind,
            channels: campaign.channels,
            message: campaign.message,
            couponID: campaign.couponID,
            isScheduled: campaign.scheduledAt != nil,
            scheduledAt: campaign.scheduledAt ?? Date.now.adding(days: 1),
            id: campaign.id.description
        )
    }

    var isEditing: Bool { original != nil }

    /// A campaign needs a name, a channel, and something to say.
    var isValid: Bool {
        !name.isBlank && !channels.isEmpty && !message.isBlank && !isOverLimit
    }

    /// Practical per-message limit: SMS is billed in 160-character segments,
    /// push notifications get truncated by the system past roughly 178.
    var characterLimit: Int {
        channels.contains(.sms) ? 160 : 178
    }

    var characterCount: Int { message.count }

    var isOverLimit: Bool { characterCount > characterLimit }

    /// Toggles a channel, keeping the display order stable.
    mutating func toggle(_ channel: Campaign.Channel) {
        if let index = channels.firstIndex(of: channel) {
            channels.remove(at: index)
        } else {
            channels.append(channel)
            channels = Campaign.Channel.allCases.filter { channels.contains($0) }
        }
    }

    /// Materializes the draft, preserving the delivery stats of an edited
    /// campaign so a copy edit never resets its reporting.
    func campaign(salonID: Salon.ID) -> Campaign {
        var campaign = original ?? Campaign(
            salonID: salonID,
            name: name,
            kind: kind,
            channels: channels,
            message: message
        )
        campaign.name = name.trimmed
        campaign.kind = kind
        campaign.channels = channels
        campaign.message = message.trimmed
        campaign.couponID = couponID
        campaign.scheduledAt = isScheduled ? scheduledAt : nil
        if campaign.status == .draft || campaign.status == .scheduled {
            campaign.status = isScheduled ? .scheduled : .draft
        }
        return campaign
    }
}

// MARK: - Coupon draft

/// The editable shape of a coupon.
struct CouponDraft: Identifiable, Hashable, Sendable {
    var original: Coupon?
    var code: String
    /// `true` for a percentage discount, `false` for a fixed amount off.
    var isPercent: Bool
    var percent: Int
    var fixedAmount: Decimal
    var hasRedemptionLimit: Bool
    var maxRedemptions: Int
    var hasMinimumSpend: Bool
    var minimumSpend: Decimal
    var hasExpiry: Bool
    var validUntil: Date
    var isActive: Bool

    let id: String

    init(
        original: Coupon? = nil,
        code: String = "",
        isPercent: Bool = true,
        percent: Int = 10,
        fixedAmount: Decimal = 10,
        hasRedemptionLimit: Bool = false,
        maxRedemptions: Int = 100,
        hasMinimumSpend: Bool = false,
        minimumSpend: Decimal = 50,
        hasExpiry: Bool = true,
        validUntil: Date = Date.now.adding(days: 60),
        isActive: Bool = true,
        id: String = UUID().uuidString
    ) {
        self.original = original
        self.code = code
        self.isPercent = isPercent
        self.percent = percent
        self.fixedAmount = fixedAmount
        self.hasRedemptionLimit = hasRedemptionLimit
        self.maxRedemptions = maxRedemptions
        self.hasMinimumSpend = hasMinimumSpend
        self.minimumSpend = minimumSpend
        self.hasExpiry = hasExpiry
        self.validUntil = validUntil
        self.isActive = isActive
        self.id = id
    }

    /// Creates a draft that edits an existing coupon.
    static func editing(_ coupon: Coupon) -> CouponDraft {
        var draft = CouponDraft(
            original: coupon,
            code: coupon.code,
            hasRedemptionLimit: coupon.maxRedemptions != nil,
            maxRedemptions: coupon.maxRedemptions ?? 100,
            hasMinimumSpend: coupon.minimumSpend != nil,
            minimumSpend: coupon.minimumSpend?.amount ?? 50,
            hasExpiry: coupon.validUntil != nil,
            validUntil: coupon.validUntil ?? Date.now.adding(days: 60),
            isActive: coupon.isActive,
            id: coupon.id.description
        )
        switch coupon.discount {
        case .percent(let value):
            draft.isPercent = true
            draft.percent = value
        case .fixed(let money):
            draft.isPercent = false
            draft.fixedAmount = money.amount
        }
        return draft
    }

    var isEditing: Bool { original != nil }

    /// Codes are uppercase, alphanumeric with dashes, and at least four long.
    var isValid: Bool {
        let trimmed = code.trimmed
        guard trimmed.count >= 4 else { return false }
        return isPercent ? (1...100).contains(percent) : fixedAmount > 0
    }

    /// Human summary of the discount, e.g. `10% off` or `€15.00 off`.
    func discountSummary(currency: Currency) -> String {
        isPercent ? "\(percent)% off" : "\(Money(fixedAmount, currency).formatted) off"
    }

    /// Materializes the draft, preserving redemptions on an edited coupon.
    func coupon(salonID: Salon.ID, currency: Currency) -> Coupon {
        var coupon = original ?? Coupon(
            salonID: salonID,
            code: code,
            discount: .percent(percent)
        )
        coupon.code = CouponDraft.normalize(code)
        coupon.discount = isPercent ? .percent(percent) : .fixed(Money(fixedAmount, currency))
        coupon.maxRedemptions = hasRedemptionLimit ? max(1, maxRedemptions) : nil
        coupon.minimumSpend = hasMinimumSpend ? Money(minimumSpend, currency) : nil
        coupon.validUntil = hasExpiry ? validUntil : nil
        coupon.isActive = isActive
        return coupon
    }

    /// Uppercases and strips anything that isn't safe to type at the till.
    static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Generates a memorable code: a salon prefix plus four random characters,
    /// e.g. `MAIS-7K2Q`. Ambiguous glyphs (O/0, I/1) are excluded.
    static func generateCode(salonName: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let prefix = salonName
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
            .prefix(4)
        let suffix = String((0 ..< 4).map { _ in alphabet.randomElement() ?? "X" })
        return prefix.isEmpty ? "PRV-\(suffix)" : "\(prefix)-\(suffix)"
    }
}

// MARK: - Model

/// Screen model behind ``MarketingView``.
///
/// Loads campaigns, coupons, and the analytics snapshot the local suggestion
/// engine reads. Suggestions are computed on device from that snapshot — no
/// campaign is ever created without an explicit tap.
@Observable
@MainActor
final class MarketingModel {
    // MARK: Selection

    var tab: MarketingTab = .campaigns

    // MARK: State

    private(set) var phase: OperationsPhase = .loading
    private(set) var salon: Salon?
    private(set) var campaigns: [Campaign] = []
    private(set) var coupons: [Coupon] = []
    private(set) var snapshot: DashboardSnapshot?
    private(set) var couponsError: String?
    private(set) var insightsError: String?

    private(set) var isSavingCampaign = false
    private(set) var isSavingCoupon = false
    private(set) var togglingCouponIDs: Set<Coupon.ID> = []

    /// The campaign composer, presented when non-`nil`.
    var campaignDraft: CampaignDraft?
    /// The coupon editor, presented when non-`nil`.
    var couponDraft: CouponDraft?

    var toast: PRVToast?
    private(set) var hasLoadedOnce = false

    // MARK: Derived

    /// Currency of the salon being operated (falls back to euro).
    var currency: Currency { salon?.currency ?? .eur }

    /// Campaigns with the liveliest first: running, scheduled, then the rest.
    var sortedCampaigns: [Campaign] {
        campaigns.sorted { lhs, rhs in
            if lhs.status.sortRank != rhs.status.sortRank {
                return lhs.status.sortRank < rhs.status.sortRank
            }
            return (lhs.scheduledAt ?? .distantPast) > (rhs.scheduledAt ?? .distantPast)
        }
    }

    /// Coupons with active ones first, then by code.
    var sortedCoupons: [Coupon] {
        coupons.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.code.localizedCaseInsensitiveCompare(rhs.code) == .orderedAscending
        }
    }

    var totalSent: Int { campaigns.reduce(0) { $0 + $1.sentCount } }
    var totalOpens: Int { campaigns.reduce(0) { $0 + $1.openCount } }
    var totalBookings: Int { campaigns.reduce(0) { $0 + $1.bookingCount } }

    var attributedRevenue: Money {
        Money(campaigns.reduce(Decimal(0)) { $0 + $1.attributedRevenue.amount }, currency)
    }

    /// Opens divided by sends, 0 when nothing has gone out yet.
    var openRate: Double {
        guard totalSent > 0 else { return 0 }
        return Double(totalOpens) / Double(totalSent)
    }

    /// Locally computed campaign ideas from the analytics snapshot.
    var suggestions: [MarketingSuggestion] {
        MarketingSuggestionEngine.suggestions(
            snapshot: snapshot,
            salon: salon,
            currency: currency,
            existingCampaigns: campaigns
        )
    }

    /// The coupon attached to a campaign, if any.
    func coupon(_ id: Coupon.ID?) -> Coupon? {
        guard let id else { return nil }
        return coupons.first { $0.id == id }
    }

    /// Whether an active toggle is mid-flight for this coupon.
    func isToggling(_ coupon: Coupon) -> Bool {
        togglingCouponIDs.contains(coupon.id)
    }

    // MARK: Loading

    /// Loads campaigns, coupons, and the analytics snapshot behind suggestions.
    func load(salonID: Salon.ID, using deps: PRVDependencies) async {
        if !hasLoadedOnce { phase = .loading }

        let end = Date.now.startOfDay().adding(days: 1)
        let start = end.adding(days: -MarketingRules.insightWindowDays)

        async let salonTask = deps.salons.salon(id: salonID)
        async let campaignsTask = deps.marketing.campaigns(salonID: salonID)
        async let couponsTask = deps.marketing.coupons(salonID: salonID)
        async let snapshotTask = deps.analytics.dashboard(
            salonID: salonID,
            periodStart: start,
            periodEnd: end
        )

        salon = try? await salonTask

        do {
            campaigns = try await campaignsTask
            phase = .loaded
        } catch {
            phase = .failed(OperationsCopy.loadMessage(for: error, subject: "your campaigns"))
        }

        do {
            coupons = try await couponsTask
            couponsError = nil
        } catch {
            coupons = []
            couponsError = OperationsCopy.loadMessage(for: error, subject: "coupons")
        }

        do {
            snapshot = try await snapshotTask
            insightsError = nil
        } catch {
            snapshot = nil
            insightsError = OperationsCopy.loadMessage(for: error, subject: "performance data")
        }

        hasLoadedOnce = true
    }

    // MARK: Composer

    /// Opens an empty composer.
    func composeCampaign() {
        PRVHaptics.tap()
        campaignDraft = CampaignDraft()
    }

    /// Opens the composer prefilled from a suggestion.
    func compose(from suggestion: MarketingSuggestion) {
        PRVHaptics.impact()
        campaignDraft = suggestion.draft
    }

    /// Opens the composer on an existing campaign.
    func edit(_ campaign: Campaign) {
        PRVHaptics.tap()
        campaignDraft = .editing(campaign)
    }

    /// Persists a campaign draft.
    /// - Returns: `true` when the composer should close.
    @discardableResult
    func saveCampaign(
        _ draft: CampaignDraft,
        salonID: Salon.ID,
        using deps: PRVDependencies
    ) async -> Bool {
        guard draft.isValid, !isSavingCampaign else { return false }
        isSavingCampaign = true
        defer { isSavingCampaign = false }

        do {
            let saved = try await deps.marketing.upsertCampaign(draft.campaign(salonID: salonID))
            if let index = campaigns.firstIndex(where: { $0.id == saved.id }) {
                campaigns[index] = saved
            } else {
                campaigns.append(saved)
            }
            PRVHaptics.success()
            toast = .success(
                saved.status == .scheduled
                    ? "\(saved.name) scheduled for \(OperationsFormat.dateTime(saved.scheduledAt ?? .now))"
                    : "\(saved.name) saved as a draft"
            )
            return true
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "save this campaign"))
            return false
        }
    }

    // MARK: Coupons

    /// Opens an empty coupon editor with a generated code.
    func createCoupon() {
        PRVHaptics.tap()
        couponDraft = CouponDraft(code: CouponDraft.generateCode(salonName: salon?.name ?? "PRV"))
    }

    /// Opens the editor on an existing coupon.
    func edit(_ coupon: Coupon) {
        PRVHaptics.tap()
        couponDraft = .editing(coupon)
    }

    /// Persists a coupon draft.
    /// - Returns: `true` when the editor should close.
    @discardableResult
    func saveCoupon(
        _ draft: CouponDraft,
        salonID: Salon.ID,
        using deps: PRVDependencies
    ) async -> Bool {
        guard draft.isValid, !isSavingCoupon else { return false }
        isSavingCoupon = true
        defer { isSavingCoupon = false }

        do {
            let saved = try await deps.marketing.upsertCoupon(
                draft.coupon(salonID: salonID, currency: currency)
            )
            apply(saved)
            PRVHaptics.success()
            toast = .success("\(saved.code) · \(saved.discountSummary)")
            return true
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "save this coupon"))
            return false
        }
    }

    /// Activates or pauses a coupon in place.
    func setActive(_ isActive: Bool, for coupon: Coupon, using deps: PRVDependencies) async {
        guard !togglingCouponIDs.contains(coupon.id) else { return }
        togglingCouponIDs.insert(coupon.id)
        defer { togglingCouponIDs.remove(coupon.id) }

        var updated = coupon
        updated.isActive = isActive

        do {
            let saved = try await deps.marketing.upsertCoupon(updated)
            apply(saved)
            toast = .success(saved.isActive ? "\(saved.code) is live" : "\(saved.code) paused")
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "update this coupon"))
        }
    }

    private func apply(_ coupon: Coupon) {
        if let index = coupons.firstIndex(where: { $0.id == coupon.id }) {
            coupons[index] = coupon
        } else {
            coupons.append(coupon)
        }
    }
}

// MARK: - Campaign display

extension Campaign.Kind {
    /// Label used on the campaign card and in the composer picker.
    var displayName: String {
        switch self {
        case .promotion: "Promotion"
        case .referral: "Referral"
        case .birthday: "Birthday"
        case .winBack: "Win-back"
        case .newService: "New service"
        case .automatic: "Automation"
        }
    }

    /// SF Symbol shown on the card's leading tile.
    var symbolName: String {
        switch self {
        case .promotion: "tag.fill"
        case .referral: "person.2.badge.plus.fill"
        case .birthday: "gift.fill"
        case .winBack: "arrow.uturn.backward.circle.fill"
        case .newService: "sparkles"
        case .automatic: "wand.and.stars"
        }
    }
}

extension Campaign.Status {
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .scheduled: "Scheduled"
        case .running: "Running"
        case .completed: "Completed"
        case .paused: "Paused"
        }
    }

    var tint: Color {
        switch self {
        case .draft: Color.prv.textSecondary
        case .scheduled: Color.prv.accent
        case .running: Color.prv.success
        case .completed: Color.prv.textSecondary
        case .paused: Color.prv.warning
        }
    }

    /// Ordering for the campaign list: live work first.
    var sortRank: Int {
        switch self {
        case .running: 0
        case .scheduled: 1
        case .paused: 2
        case .draft: 3
        case .completed: 4
        }
    }
}

extension Campaign.Channel {
    /// SF Symbol shown on the channel chip.
    var symbolName: String {
        switch self {
        case .push: "bell.badge.fill"
        case .email: "envelope.fill"
        case .sms: "message.fill"
        }
    }
}

// MARK: - Coupon display

extension Coupon {
    /// Human summary of the discount, e.g. `10% off` or `€15.00 off`.
    var discountSummary: String {
        switch discount {
        case .percent(let value): "\(value)% off"
        case .fixed(let money): "\(money.formatted) off"
        }
    }

    /// Redemptions used against the cap, or `nil` when unlimited.
    var redemptionFraction: Double? {
        guard let maxRedemptions, maxRedemptions > 0 else { return nil }
        return min(1, Double(redemptionCount) / Double(maxRedemptions))
    }

    /// Whether the coupon has passed its end date.
    var isExpired: Bool {
        guard let validUntil else { return false }
        return validUntil < .now
    }

    /// Whether the redemption cap has been reached.
    var isExhausted: Bool {
        guard let maxRedemptions else { return false }
        return redemptionCount >= maxRedemptions
    }
}
