import Foundation
import PRVFoundation
import PRVModels

/// The live ``MarketingRepository``, backed by the `campaigns`, `coupons`, and
/// `coupon_redemptions` tables.
///
/// The split `0002_rls.sql` draws is the one this repository is shaped around: a
/// coupon code is only useful if a client can validate it, so
/// `coupons_select_active` exposes *active, in-window* coupons to any signed-in
/// user while the campaign economics behind them stay staff-only. Redemption
/// counts are never written from here — `coupon_redemptions` is the audit trail
/// and the `refresh_coupon_redemption_count` trigger in
/// `0003_functions_triggers.sql` owns `coupons.redemption_count`, so a device
/// cannot talk a coupon out of its own limit.
public struct SupabaseMarketingRepository: MarketingRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns.
    private static let listLimit = 100

    /// How many candidates a code lookup will consider. Only reached when the
    /// code contains a character that forces the substring fallback in
    /// ``codeFilter(_:)``; the exact filter returns at most one row, because
    /// `coupons_salon_code_key` is unique on `(salon_id, upper(code))`.
    private static let validationLimit = 50

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Campaigns

    /// The salon's campaigns, newest first.
    public func campaigns(salonID: Salon.ID) async throws -> [Campaign] {
        let request = PostgRESTQuery("campaigns")
            .filter(.equals("salon_id", salonID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [CampaignRow] = try await client.select(request)
        return rows.map(Self.makeCampaign)
    }

    /// Creates or replaces a campaign, returning it as stored.
    ///
    /// The upsert resolves on the primary key, matching
    /// `InMemoryBackend.upsertCampaign(_:)`. Delivery counters travel with the
    /// value because the composer owns them while a campaign is still a draft;
    /// once `notify-fanout` starts sending, the Edge Function is what advances
    /// them, and the stored representation is what comes back.
    public func upsertCampaign(_ campaign: Campaign) async throws -> Campaign {
        let payload = CampaignUpsert(
            id: campaign.id.rawValue,
            salonID: campaign.salonID.rawValue,
            name: campaign.name,
            kind: campaign.kind.rawValue,
            channels: campaign.channels.map(\.rawValue),
            message: campaign.message,
            couponID: SupabaseNullableColumn(campaign.couponID?.rawValue),
            status: campaign.status.rawValue,
            scheduledAt: SupabaseNullableColumn(
                campaign.scheduledAt.map(SupabaseTimestamp.string(from:))
            ),
            sentCount: campaign.sentCount,
            openCount: campaign.openCount,
            bookingCount: campaign.bookingCount,
            attributedRevenueAmount: campaign.attributedRevenue.amount,
            currency: campaign.attributedRevenue.currency.rawValue
        )
        let row: CampaignRow = try await client.upsert(
            into: "campaigns",
            values: payload,
            onConflict: "id"
        )
        return Self.makeCampaign(row)
    }

    // MARK: - Coupons

    /// The salon's coupons, newest first.
    public func coupons(salonID: Salon.ID) async throws -> [Coupon] {
        let request = PostgRESTQuery("coupons")
            .filter(.equals("salon_id", salonID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [CouponRow] = try await client.select(request)
        return try rows.map(Self.makeCoupon)
    }

    /// Creates or replaces a coupon, returning it as stored.
    ///
    /// `Coupon.Discount` is an enum with associated values and the schema stores
    /// it as a discriminator plus two payload columns, exactly one of which may
    /// be set. Both columns are therefore always written — the unused one as an
    /// explicit `null` — so switching a live coupon from `percent` to `fixed`
    /// leaves no stale percentage behind for `coupons_percent_payload` to reject.
    ///
    /// `redemption_count` is never sent. It is derived from
    /// `coupon_redemptions` by trigger, which is what makes the limit
    /// ``validateCoupon(code:salonID:)`` enforces a server-side fact rather than
    /// a number the client last saw.
    public func upsertCoupon(_ coupon: Coupon) async throws -> Coupon {
        let discountKind: String
        var discountPercent: Int?
        var discountAmount: Decimal?
        var currency = coupon.minimumSpend?.currency ?? .eur

        switch coupon.discount {
        case .percent(let percent):
            discountKind = "percent"
            discountPercent = percent
        case .fixed(let money):
            discountKind = "fixed"
            discountAmount = money.amount
            currency = money.currency
        }

        let payload = CouponUpsert(
            id: coupon.id.rawValue,
            salonID: coupon.salonID.rawValue,
            code: coupon.code,
            discountKind: discountKind,
            discountPercent: SupabaseNullableColumn(discountPercent),
            discountAmount: SupabaseNullableColumn(discountAmount),
            currency: currency.rawValue,
            maxRedemptions: SupabaseNullableColumn(coupon.maxRedemptions),
            minimumSpendAmount: SupabaseNullableColumn(coupon.minimumSpend?.amount),
            validFrom: SupabaseTimestamp.string(from: coupon.validFrom),
            validUntil: SupabaseNullableColumn(
                coupon.validUntil.map(SupabaseTimestamp.string(from:))
            ),
            isActive: coupon.isActive
        )
        let row: CouponRow = try await client.upsert(
            into: "coupons",
            values: payload,
            onConflict: "id"
        )
        return try Self.makeCoupon(row)
    }

    /// Validates a coupon code for a salon.
    ///
    /// Every rule `InMemoryBackend.validateCoupon(code:salonID:)` applies is
    /// applied here, and all but one of them server-side, so an invalid coupon is
    /// never handed to the device at all:
    ///
    /// - the salon and the code match (case-insensitively);
    /// - `is_active` is true;
    /// - `now()` lies inside `[valid_from, valid_until)`;
    /// - the redemption limit is not yet reached.
    ///
    /// Only the last is evaluated on the returned row, because PostgREST cannot
    /// express a comparison between two columns (`redemption_count <
    /// max_redemptions`). The number it compares is still authoritative:
    /// `redemption_count` is trigger-maintained, and the ledger it counts is
    /// `coupon_redemptions`.
    ///
    /// The `valid_from` bound is checked even though `InMemoryBackend` has no
    /// such data, because `coupons_select_active` checks it: without it, staff —
    /// who can see their own salon's coupons regardless — would get a different
    /// answer from the one their clients get.
    ///
    /// - Throws: ``APIError/notFound`` when the code is unknown, inactive,
    ///   outside its window, or exhausted. The four are deliberately
    ///   indistinguishable, so a code cannot be probed for its state.
    public func validateCoupon(code: String, salonID: Salon.ID) async throws -> Coupon {
        let needle = code.trimmed
        guard !needle.isEmpty else { throw APIError.notFound }

        let now = SupabaseTimestamp.string(from: .now)
        let request = PostgRESTQuery("coupons")
            .filter(.equals("salon_id", salonID.rawValue))
            .filter(Self.codeFilter(needle))
            .filter(.isTrue("is_active"))
            .filter(.atMost("valid_from", now))
            .filter(.any(of: [.isNull("valid_until"), .greaterThan("valid_until", now)]))
            .limited(to: Self.validationLimit)

        let rows: [CouponRow] = try await client.select(request)
        guard let row = rows.first(where: { $0.code.caseInsensitiveCompare(needle) == .orderedSame })
        else { throw APIError.notFound }

        let coupon = try Self.makeCoupon(row)
        guard coupon.maxRedemptions.map({ coupon.redemptionCount < $0 }) ?? true else {
            throw APIError.notFound
        }
        return coupon
    }

    /// The filter that matches a coupon code exactly, ignoring case.
    ///
    /// `coupons_salon_code_key` indexes `upper(code)` and PostgREST cannot filter
    /// on an expression index, so case-insensitivity comes from `ilike`. A
    /// pattern carrying no wildcard makes `ilike` an exact match, which is
    /// precisely what a code lookup wants — but a literal `%` or `_` in the code
    /// would turn it back into a wildcard, and PostgREST's own structure
    /// characters would need quoting. Those cases fall back to the vetted
    /// substring filter and are narrowed to one row by the exact comparison the
    /// caller performs on the result.
    private static func codeFilter(_ code: String) -> PostgRESTFilter {
        let ambiguous = CharacterSet(charactersIn: "%_,()\"\\{}")
        guard code.rangeOfCharacter(from: ambiguous) == nil else {
            return .caseInsensitiveContains("code", code)
        }
        return PostgRESTFilter(name: "code", value: "ilike.\(code)")
    }

    // MARK: - Row mapping

    private static func makeCampaign(_ row: CampaignRow) -> Campaign {
        Campaign(
            id: Campaign.ID(row.id),
            salonID: Salon.ID(row.salonID),
            name: row.name,
            kind: Campaign.Kind(rawValue: row.kind) ?? .promotion,
            channels: row.channels.compactMap(Campaign.Channel.init(rawValue:)),
            message: row.message,
            couponID: row.couponID.map { Coupon.ID($0) },
            status: Campaign.Status(rawValue: row.status) ?? .draft,
            scheduledAt: SupabaseTimestamp.optionalDate(from: row.scheduledAt),
            sentCount: row.sentCount,
            openCount: row.openCount,
            bookingCount: row.bookingCount,
            attributedRevenue: Money(
                row.attributedRevenueAmount,
                Currency(rawValue: row.currency.trimmed) ?? .eur
            )
        )
    }

    private static func makeCoupon(_ row: CouponRow) throws -> Coupon {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        let discount: Coupon.Discount = row.discountKind == "fixed"
            ? .fixed(Money(row.discountAmount ?? 0, currency))
            : .percent(row.discountPercent ?? 0)
        return Coupon(
            id: Coupon.ID(row.id),
            salonID: Salon.ID(row.salonID),
            code: row.code,
            discount: discount,
            maxRedemptions: row.maxRedemptions,
            redemptionCount: row.redemptionCount,
            minimumSpend: row.minimumSpendAmount.map { Money($0, currency) },
            validFrom: try SupabaseTimestamp.date(from: row.validFrom),
            validUntil: SupabaseTimestamp.optionalDate(from: row.validUntil),
            isActive: row.isActive
        )
    }
}

// MARK: - Rows

extension SupabaseMarketingRepository {
    /// A `campaigns` row.
    fileprivate struct CampaignRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let name: String
        let kind: String
        let channels: [String]
        let message: String
        let couponID: UUID?
        let status: String
        let scheduledAt: String?
        let sentCount: Int
        let openCount: Int
        let bookingCount: Int
        let attributedRevenueAmount: Decimal
        let currency: String
    }

    /// A `coupons` row.
    fileprivate struct CouponRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let code: String
        let discountKind: String
        let discountPercent: Int?
        let discountAmount: Decimal?
        let currency: String
        let maxRedemptions: Int?
        let redemptionCount: Int
        let minimumSpendAmount: Decimal?
        let validFrom: String
        let validUntil: String?
        let isActive: Bool
    }
}

// MARK: - Payloads

extension SupabaseMarketingRepository {
    /// A whole campaign, merged onto the primary key.
    fileprivate struct CampaignUpsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let name: String
        let kind: String
        let channels: [String]
        let message: String
        let couponID: SupabaseNullableColumn<UUID>
        let status: String
        let scheduledAt: SupabaseNullableColumn<String>
        let sentCount: Int
        let openCount: Int
        let bookingCount: Int
        let attributedRevenueAmount: Decimal
        let currency: String
    }

    /// A whole coupon, merged onto the primary key.
    ///
    /// `redemption_count` is absent by design: the trigger that counts
    /// `coupon_redemptions` owns it.
    fileprivate struct CouponUpsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let code: String
        let discountKind: String
        let discountPercent: SupabaseNullableColumn<Int>
        let discountAmount: SupabaseNullableColumn<Decimal>
        let currency: String
        let maxRedemptions: SupabaseNullableColumn<Int>
        let minimumSpendAmount: SupabaseNullableColumn<Decimal>
        let validFrom: String
        let validUntil: SupabaseNullableColumn<String>
        let isActive: Bool
    }
}
