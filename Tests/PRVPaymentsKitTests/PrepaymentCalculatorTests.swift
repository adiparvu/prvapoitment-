import Foundation
import PRVModels
import PRVPaymentsKit
import Testing

@Suite("PrepaymentCalculator")
struct PrepaymentCalculatorTests {
    private let calculator = PrepaymentCalculator()
    private let total = Money(200)

    private func makeQuote(
        _ percent: PrepaymentPolicy.Percent?,
        policy: PrepaymentPolicy = Fixtures.standardPolicy,
        orderTotal: Money = Money(200)
    ) -> PrepaymentQuote {
        calculator.quote(policy: policy, percent: percent, orderTotal: orderTotal)
    }

    @Test("Partial prepayment charges its percentage and keeps the list price")
    func partialPrepaymentLevels() {
        let expectations: [(level: PrepaymentPolicy.Percent, payNow: String, payLater: String, cashback: String)] = [
            (.ten, "20.00", "180.00", "0.40"),
            (.twenty, "40.00", "160.00", "0.80"),
            (.thirty, "60.00", "140.00", "1.20"),
            (.fifty, "100.00", "100.00", "2.00"),
        ]

        for expectation in expectations {
            let result = makeQuote(expectation.level)

            #expect(result.discount == Money(0), "\(expectation.level) should not be discounted")
            #expect(result.payNow == Fixtures.eur(expectation.payNow))
            #expect(result.payLater == Fixtures.eur(expectation.payLater))
            #expect(result.cashback == Fixtures.eur(expectation.cashback))
            #expect(result.pointsMultiplier == 2)
            #expect(result.grantsPriority)
            #expect(result.isPrepaid)
            #expect(!result.isFullPrepayment)
            #expect(result.title == "Prepay \(expectation.level.rawValue)%")
        }
    }

    @Test("Full prepayment earns the salon's discount and settles the order")
    func fullPrepaymentEarnsTheDiscount() {
        let result = makeQuote(.full)

        #expect(result.discount == Money(20))
        #expect(result.payNow == Money(180))
        #expect(result.payLater == Money(0))
        #expect(result.payableTotal == Money(180))
        #expect(result.cashback == Fixtures.eur("3.60"))
        #expect(result.pointsMultiplier == 2)
        #expect(result.isFullPrepayment)
        #expect(result.title == "Pay in full")
    }

    @Test("Paying at the salon charges nothing and earns nothing")
    func payAtSalonEarnsNothing() {
        let result = makeQuote(nil)

        #expect(result.discount == Money(0))
        #expect(result.payNow == Money(0))
        #expect(result.payLater == Money(200))
        #expect(result.cashback == Money(0))
        #expect(result.pointsMultiplier == 1)
        #expect(!result.grantsPriority)
        #expect(!result.isPrepaid)
        #expect(!result.hasIncentives)
        #expect(result.title == "Pay at the salon")
        #expect(result.subtitle == "Nothing is charged now")
    }

    @Test("Every level reconciles: pay now + pay later + discount == the total")
    func everyLevelReconciles() {
        let levels: [PrepaymentPolicy.Percent?] =
            PrepaymentPolicy.Percent.allCases.map { Optional($0) } + [nil]
        let totals = [Money(200), Fixtures.eur("33.33"), Fixtures.eur("0.01"), Money(0), Fixtures.eur("1249.99")]

        for orderTotal in totals {
            for level in levels {
                let result = makeQuote(level, orderTotal: orderTotal)
                #expect(
                    result.payNow + result.payLater + result.discount == orderTotal,
                    "Level \(String(describing: level)) lost a cent on \(orderTotal.formatted)"
                )
                #expect(result.payNow.amount >= 0)
                #expect(result.payLater.amount >= 0)
                #expect(result.discount.amount >= 0)
            }
        }
    }

    @Test("Odd totals split to the cent with banker's rounding")
    func oddTotalsSplitExactly() {
        // 33.33 × 30% = 9.999 → 10.00, leaving 23.33.
        let result = makeQuote(.thirty, orderTotal: Fixtures.eur("33.33"))

        #expect(result.payNow == Money(10))
        #expect(result.payLater == Fixtures.eur("23.33"))
        #expect(result.payableTotal == Fixtures.eur("33.33"))
    }

    @Test("A salon with no incentives discounts nothing and grants nothing")
    func barePolicyGrantsNothing() {
        let result = makeQuote(.full, policy: Fixtures.barePolicy)

        #expect(result.discount == Money(0))
        #expect(result.payNow == Money(200))
        #expect(result.cashback == Money(0))
        #expect(result.pointsMultiplier == 1)
        #expect(!result.grantsPriority)
        #expect(!result.hasIncentives)
    }

    @Test("Offered levels are listed in order, always ending with pay-at-salon")
    func offeredLevelsAreOrdered() {
        let quotes = calculator.quotes(policy: Fixtures.standardPolicy, orderTotal: total)

        #expect(quotes.map(\.percent) == [.twenty, .fifty, .full, nil])
        #expect(quotes.last?.isPrepaid == false)
        #expect(quotes.map(\.id) == [20, 50, 100, 0])
    }

    @Test("The minimum deposit is the smallest level the salon offers")
    func minimumDepositIsTheSmallestLevel() {
        #expect(calculator.minimumDeposit(policy: Fixtures.standardPolicy, orderTotal: total) == Money(40))
        #expect(calculator.minimumDeposit(policy: Fixtures.barePolicy, orderTotal: total) == Money(20))
        #expect(calculator.minimumDeposit(policy: PrepaymentPolicy(offeredPercents: []), orderTotal: total) == nil)
    }

    @Test("Negative totals clamp to zero rather than inverting the split")
    func negativeTotalsClampToZero() {
        let result = makeQuote(.fifty, orderTotal: Money(-50))

        #expect(result.orderTotal == Money(0))
        #expect(result.payNow == Money(0))
        #expect(result.payLater == Money(0))
        #expect(result.discount == Money(0))
    }

    @Test("Reward points multiply on prepaid orders only")
    func rewardPointsMultiplyWhenPrepaid() {
        #expect(calculator.rewardPoints(for: total, percent: nil, policy: Fixtures.standardPolicy) == 200)
        #expect(calculator.rewardPoints(for: total, percent: .fifty, policy: Fixtures.standardPolicy) == 400)
        // Full prepayment earns double points on the discounted €180.
        #expect(calculator.rewardPoints(for: total, percent: .full, policy: Fixtures.standardPolicy) == 360)
    }
}
