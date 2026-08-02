import Foundation
import PRVModels
import PRVPaymentsKit

/// Deterministic money fixtures.
///
/// Every `Decimal` here is built from a string or an integer — never a float
/// literal — so no test result can depend on binary floating-point conversion.
/// Dates come from a fixed UTC calendar, and no assertion ever reads
/// `Date.now`.
enum Fixtures {
    // MARK: Calendar & dates

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date(timeIntervalSince1970: 0)
    }

    /// The reference "now" for coupon validity: Monday 2 March 2026, 10:00 UTC.
    static var now: Date { date(2026, 3, 2, 10) }
    /// The appointment the fixtures settle: Thursday 5 March 2026, 14:00 UTC.
    static var visit: Date { date(2026, 3, 5, 14) }

    // MARK: Money

    /// Builds an exact decimal from its decimal string.
    static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .zero
    }

    /// Builds an exact euro amount from its decimal string, e.g. `eur("33.34")`.
    static func eur(_ text: String) -> Money {
        Money(decimal(text))
    }

    // MARK: Catalogue

    static let salonID = PreviewData.salonLumiere.id
    static let clientID = PreviewData.client.id

    /// €185 balayage with a €35 Olaplex add-on.
    static let balayage = PreviewData.serviceBalayage
    static let olaplex = PreviewData.serviceBalayage.addOns[0]

    /// The default order priced by most tests: €185 service + €35 add-on = €220.
    static var standardItems: [PricingItem] {
        [PricingItem(service: balayage, addOns: [olaplex])]
    }

    // MARK: Policies

    /// The platform default: 20/50/100% offered, 10% off full prepayment,
    /// double points, 2% cashback, priority booking.
    static let standardPolicy = PrepaymentPolicy()

    /// A salon offering every level with no incentives at all.
    static let barePolicy = PrepaymentPolicy(
        offeredPercents: PrepaymentPolicy.Percent.allCases,
        fullPrepaymentDiscountPercent: 0,
        rewardPointsMultiplier: 0,
        cashbackPercent: 0,
        grantsPriorityBooking: false
    )

    // MARK: Coupons

    /// Builds a coupon valid across the whole reference week.
    static func coupon(
        code: String = "SPRING",
        discount: Coupon.Discount,
        minimumSpend: Money? = nil,
        maxRedemptions: Int? = nil,
        redemptionCount: Int = 0,
        isActive: Bool = true,
        validFrom: Date = date(2026, 3, 1),
        validUntil: Date? = date(2026, 3, 31),
        salonID: Salon.ID = Fixtures.salonID
    ) -> Coupon {
        Coupon(
            salonID: salonID,
            code: code,
            discount: discount,
            maxRedemptions: maxRedemptions,
            redemptionCount: redemptionCount,
            minimumSpend: minimumSpend,
            validFrom: validFrom,
            validUntil: validUntil,
            isActive: isActive
        )
    }

    // MARK: Memberships

    /// An active Gold subscription granting 15% off.
    static func subscription(status: MembershipSubscription.Status = .active) -> MembershipSubscription {
        MembershipSubscription(
            planID: PreviewData.goldPlan.id,
            plan: PreviewData.goldPlan,
            userID: clientID,
            status: status,
            startedAt: date(2026, 1, 1),
            renewsAt: date(2026, 4, 1)
        )
    }

    // MARK: Requests

    /// A pricing request over ``standardItems`` with everything else neutral.
    static func request(
        items: [PricingItem] = Fixtures.standardItems,
        coupon: Coupon? = nil,
        membershipDiscountPercent: Decimal = 0,
        prepayment: PrepaymentPolicy.Percent? = nil,
        policy: PrepaymentPolicy = Fixtures.standardPolicy,
        tip: Tip = .none,
        vatPercent: Decimal = 21
    ) -> PricingRequest {
        PricingRequest(
            items: items,
            coupon: coupon,
            salonID: salonID,
            membershipDiscountPercent: membershipDiscountPercent,
            prepayment: prepayment,
            prepaymentPolicy: policy,
            tip: tip,
            vatPercent: vatPercent,
            currency: .eur,
            now: now
        )
    }
}
