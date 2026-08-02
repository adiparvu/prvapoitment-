import Foundation
import PRVModels
import PRVPaymentsKit
import Testing

@Suite("PaymentPlanner")
struct PaymentPlannerTests {
    private let planner = PaymentPlanner()

    // MARK: - Even splits

    @Test("€100 across three payers is 33.34 / 33.33 / 33.33 — never a lost cent")
    func hundredAcrossThree() {
        let plan = planner.splitEvenly(total: Money(100), ways: 3)

        #expect(plan.shares.map(\.amount) == [
            Fixtures.eur("33.34"), Fixtures.eur("33.33"), Fixtures.eur("33.33"),
        ])
        #expect(plan.allocated == Money(100))
        #expect(plan.isExact)
        #expect(plan.largestShare == Fixtures.eur("33.34"))
    }

    @Test("Even splits stay exact for every awkward total and party size")
    func evenSplitsAlwaysReconcile() {
        let totals = [Money(100), Fixtures.eur("0.01"), Fixtures.eur("99.99"), Money(0), Fixtures.eur("185.55")]

        for total in totals {
            for ways in 1...9 {
                let plan = planner.splitEvenly(total: total, ways: ways)
                #expect(plan.shares.count == ways)
                #expect(plan.isExact, "\(total.formatted) across \(ways) lost a cent")
                #expect(plan.shares.allSatisfy { $0.amount.amount >= 0 })
            }
        }
    }

    @Test("A single cent across three payers goes to exactly one of them")
    func singleCentGoesToOnePayer() {
        let plan = planner.splitEvenly(total: Fixtures.eur("0.01"), ways: 3)

        #expect(plan.shares.map(\.amount) == [Fixtures.eur("0.01"), Money(0), Money(0)])
        #expect(plan.isExact)
    }

    @Test("Splitting zero ways yields no shares rather than a crash")
    func zeroWaysYieldsNoShares() {
        let plan = planner.splitEvenly(total: Money(100), ways: 0)

        #expect(plan.shares.isEmpty)
        #expect(plan.allocated == Money(0))
        #expect(!plan.isExact)
    }

    @Test("Named payers keep their identity on their share")
    func namedPayersKeepIdentity() {
        let payers = [
            SplitPayer(userID: PreviewData.client.id, name: "Sofia"),
            SplitPayer(name: "Marie"),
        ]
        let plan = planner.splitEvenly(total: Fixtures.eur("75.01"), among: payers)

        #expect(plan.shares.map(\.label) == ["Sofia", "Marie"])
        #expect(plan.shares[0].payerID == PreviewData.client.id)
        #expect(plan.shares[1].payerID == nil)
        #expect(plan.shares.map(\.amount) == [Fixtures.eur("37.51"), Fixtures.eur("37.50")])
        #expect(plan.isExact)
    }

    // MARK: - Itemized splits

    @Test("An itemized split charges everyone for what they had")
    func itemizedSplitIsProportional() {
        let plan = planner.split(total: Money(220), byAmounts: [Money(185), Money(35)])

        #expect(plan.shares.map(\.amount) == [Money(185), Money(35)])
        #expect(plan.isExact)
    }

    @Test("Proportional splits distribute remainder cents by largest remainder")
    func proportionalSplitDistributesRemainders() {
        let payers = (0..<3).map { SplitPayer(name: "Payer \($0 + 1)", weight: 1) }
        let plan = planner.split(total: Money(100), among: payers)

        #expect(plan.shares.map(\.amount) == [
            Fixtures.eur("33.34"), Fixtures.eur("33.33"), Fixtures.eur("33.33"),
        ])
        #expect(plan.isExact)
    }

    @Test("All-zero weights fall back to an even split")
    func zeroWeightsSplitEvenly() {
        let payers = (0..<4).map { SplitPayer(name: "Payer \($0 + 1)", weight: 0) }
        let plan = planner.split(total: Fixtures.eur("10.02"), among: payers)

        #expect(plan.shares.map(\.amount) == [
            Fixtures.eur("2.51"), Fixtures.eur("2.51"), Fixtures.eur("2.50"), Fixtures.eur("2.50"),
        ])
        #expect(plan.isExact)
    }

    // MARK: - Deposit schedules

    @Test("A deposit schedule always adds back up to the total")
    func depositScheduleReconciles() {
        let schedule = planner.depositSchedule(
            total: Fixtures.eur("33.33"),
            depositPercent: 30,
            depositDueAt: Fixtures.now,
            balanceDueAt: Fixtures.visit
        )

        #expect(schedule.deposit?.amount == Money(10))
        #expect(schedule.balance?.amount == Fixtures.eur("23.33"))
        #expect(schedule.isExact)
        #expect(schedule.installments.map(\.kind) == [.deposit, .balance])
        #expect(schedule.amountDue(by: Fixtures.now) == Money(10))
        #expect(schedule.amountDue(by: Fixtures.visit) == Fixtures.eur("33.33"))
    }

    @Test("A 100% deposit collapses to a single paid-in-full line")
    func fullDepositCollapsesTheSchedule() {
        let schedule = planner.depositSchedule(
            total: Money(180),
            depositPercent: 100,
            depositDueAt: Fixtures.now,
            balanceDueAt: Fixtures.visit
        )

        #expect(schedule.installments.count == 1)
        #expect(schedule.deposit?.amount == Money(180))
        #expect(schedule.deposit?.label == "Paid in full")
        #expect(schedule.balance == nil)
        #expect(schedule.isExact)
    }

    @Test("A zero deposit leaves only the balance at the salon")
    func zeroDepositLeavesOnlyTheBalance() {
        let schedule = planner.depositSchedule(
            total: Money(180),
            depositPercent: 0,
            depositDueAt: Fixtures.now,
            balanceDueAt: Fixtures.visit
        )

        #expect(schedule.installments.count == 1)
        #expect(schedule.deposit == nil)
        #expect(schedule.balance?.amount == Money(180))
        #expect(schedule.amountDue(by: Fixtures.now) == Money(0))
        #expect(schedule.isExact)
    }

    @Test("A deposit larger than the order is capped at the order")
    func oversizedDepositIsCapped() {
        let schedule = planner.depositSchedule(
            total: Money(180),
            deposit: Money(500),
            depositDueAt: Fixtures.now,
            balanceDueAt: Fixtures.visit
        )

        #expect(schedule.deposit?.amount == Money(180))
        #expect(schedule.balance == nil)
        #expect(schedule.isExact)
    }

    @Test("A schedule built from a prepayment quote matches the quote")
    func scheduleFromPrepaymentQuote() {
        let quote = PrepaymentCalculator().quote(
            policy: Fixtures.standardPolicy,
            percent: .twenty,
            orderTotal: Money(220)
        )
        let schedule = planner.schedule(for: quote, depositDueAt: Fixtures.now, balanceDueAt: Fixtures.visit)

        #expect(schedule.total == Money(220))
        #expect(schedule.deposit?.amount == quote.payNow)
        #expect(schedule.balance?.amount == quote.payLater)
        #expect(schedule.isExact)
    }

    // MARK: - Instalments

    @Test("Instalments are equal, dated, and exact")
    func installmentsAreEqualAndExact() {
        let schedule = planner.installmentSchedule(
            total: Money(100),
            count: 3,
            firstDueAt: Fixtures.now,
            intervalDays: 30,
            calendar: Fixtures.calendar
        )

        #expect(schedule.installments.map(\.amount) == [
            Fixtures.eur("33.34"), Fixtures.eur("33.33"), Fixtures.eur("33.33"),
        ])
        #expect(schedule.installments.map(\.label) == [
            "Payment 1 of 3", "Payment 2 of 3", "Payment 3 of 3",
        ])
        #expect(schedule.installments[0].dueAt == Fixtures.now)
        #expect(schedule.installments[1].dueAt == Fixtures.date(2026, 4, 1, 10))
        #expect(schedule.installments[2].dueAt == Fixtures.date(2026, 5, 1, 10))
        #expect(schedule.isExact)
    }

    @Test("A non-positive instalment count yields an empty schedule")
    func nonPositiveInstallmentCount() {
        let schedule = planner.installmentSchedule(total: Money(100), count: 0, firstDueAt: Fixtures.now)

        #expect(schedule.installments.isEmpty)
        #expect(!schedule.isExact)
    }
}
