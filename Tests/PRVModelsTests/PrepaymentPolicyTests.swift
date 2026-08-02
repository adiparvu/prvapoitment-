import Foundation
import PRVModels
import Testing

@Suite("Prepayment & salon policies")
struct PrepaymentPolicyTests {
    @Test("The default prepayment policy is the platform's published incentive set")
    func defaultsMatchThePublishedIncentives() {
        let policy = PrepaymentPolicy()

        #expect(policy.offeredPercents == [.twenty, .fifty, .full])
        #expect(policy.fullPrepaymentDiscountPercent == 10)
        #expect(policy.rewardPointsMultiplier == 2)
        #expect(policy.cashbackPercent == 2)
        #expect(policy.grantsPriorityBooking)
    }

    @Test("Prepayment levels carry their percentage as their raw value")
    func percentRawValuesAreThePercentages() {
        #expect(PrepaymentPolicy.Percent.ten.rawValue == 10)
        #expect(PrepaymentPolicy.Percent.twenty.rawValue == 20)
        #expect(PrepaymentPolicy.Percent.thirty.rawValue == 30)
        #expect(PrepaymentPolicy.Percent.fifty.rawValue == 50)
        #expect(PrepaymentPolicy.Percent.full.rawValue == 100)
        #expect(PrepaymentPolicy.Percent.allCases.map(\.rawValue) == [10, 20, 30, 50, 100])
        #expect(PrepaymentPolicy.Percent(rawValue: 20) == .twenty)
        #expect(PrepaymentPolicy.Percent(rawValue: 33) == nil)
    }

    @Test("A prepayment level applied to a price yields the exact deposit")
    func prepaymentPercentagesProduceExactDeposits() {
        let price = Money(185)

        #expect(price.percentage(Decimal(PrepaymentPolicy.Percent.twenty.rawValue)) == Money(37))
        #expect(price.percentage(Decimal(PrepaymentPolicy.Percent.fifty.rawValue)) == ModelFixtures.money("92.50"))
        #expect(price.percentage(Decimal(PrepaymentPolicy.Percent.full.rawValue)) == price)
    }

    @Test("The default cancellation policy is the platform's 24-hour window")
    func defaultCancellationPolicy() {
        let policies = SalonPolicies()

        #expect(policies.freeCancellationHours == 24)
        #expect(policies.lateCancellationFeePercent == 50)
        #expect(policies.noShowFeePercent == 100)
        #expect(policies.lateGraceMinutes == 10)
        #expect(policies.childrenAllowed)
        #expect(policies.notes == nil)
    }

    @Test("A new salon inherits both default policies without being asked")
    func salonsInheritDefaultPolicies() {
        let salon = Salon(
            name: "Velvet Nails Studio",
            categories: [.nailStudio],
            address: Address(
                street: "Rue du Bailli 58",
                city: "Brussels",
                postalCode: "1050",
                country: "BE",
                coordinate: GeoCoordinate(latitude: 50.75, longitude: 4.25)
            ),
            createdAt: ModelFixtures.reference
        )

        #expect(salon.prepaymentPolicy == PrepaymentPolicy())
        #expect(salon.policies == SalonPolicies())
        #expect(salon.currency == .eur)
        #expect(salon.languages == ["en"])
        #expect(!salon.isVerified)
        #expect(salon.rating == 0)
    }

    @Test("Policies survive the wire format with snake_case keys")
    func policiesRoundTrip() throws {
        let policy = PrepaymentPolicy(
            offeredPercents: [.ten, .thirty],
            fullPrepaymentDiscountPercent: 15,
            rewardPointsMultiplier: 3,
            cashbackPercent: 5,
            grantsPriorityBooking: false
        )
        let decoded = try PRVWireJSON.roundTrip(policy)

        #expect(decoded == policy)

        let keys = try PRVWireJSON.wireKeys(for: policy)
        #expect(keys.contains("offered_percents"))
        #expect(keys.contains("full_prepayment_discount_percent"))
        #expect(keys.contains("reward_points_multiplier"))
        #expect(keys.contains("grants_priority_booking"))
    }

    @Test("Opening hours model closed days as an empty interval list")
    func closedDaysAreEmptyIntervals() {
        let sunday = OpeningHours(weekday: 1, intervals: [])
        let monday = OpeningHours(weekday: 2, intervals: [.init(openMinutes: 540, closeMinutes: 1_140)])

        #expect(sunday.isClosed)
        #expect(!monday.isClosed)
        #expect(monday.intervals.first?.openMinutes == 540)
    }
}
