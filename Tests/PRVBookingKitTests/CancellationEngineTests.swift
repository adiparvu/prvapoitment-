import Foundation
import PRVBookingKit
import PRVModels
import Testing

@Suite("CancellationEngine")
struct CancellationEngineTests {
    private let engine = CancellationEngine(calendar: Fixtures.calendar)

    /// 24-hour free window, 50% late fee, 100% no-show fee — the platform default.
    private let policies = SalonPolicies(
        freeCancellationHours: 24,
        lateCancellationFeePercent: 50,
        noShowFeePercent: 100
    )

    private var start: Date { Fixtures.mondayAt(14) }
    private let paid = Money(200)

    private func assess(now: Date, trigger: CancellationEngine.Trigger = .clientCancellation) -> CancellationAssessment {
        engine.assess(policies: policies, appointmentStart: start, now: now, amountPaid: paid, trigger: trigger)
    }

    @Test("Cancelling well before the free window costs nothing")
    func earlyCancellationIsFree() {
        let assessment = assess(now: Fixtures.date(2026, 2, 28, 14))

        #expect(assessment.outcome == .withinFreeWindow)
        #expect(assessment.isFree)
        #expect(assessment.feePercent == 0)
        #expect(assessment.fee == Money(0))
        #expect(assessment.refundDue == Money(200))
    }

    @Test("The free-cancellation boundary is inclusive")
    func boundaryIsInclusive() {
        let onTheBoundary = assess(now: Fixtures.date(2026, 3, 1, 14))

        #expect(onTheBoundary.outcome == .withinFreeWindow)
        #expect(onTheBoundary.isFree)
        #expect(engine.isWithinFreeWindow(policies: policies, appointmentStart: start, now: Fixtures.date(2026, 3, 1, 14)))
        #expect(engine.freeCancellationDeadline(policies: policies, appointmentStart: start) == Fixtures.date(2026, 3, 1, 14))
    }

    @Test("One minute inside the window triggers the late-cancellation fee")
    func lateCancellationChargesLateFee() {
        let assessment = assess(now: Fixtures.date(2026, 3, 1, 14, 1))

        #expect(assessment.outcome == .lateCancellation)
        #expect(!assessment.isFree)
        #expect(assessment.feePercent == 50)
        #expect(assessment.fee == Money(100))
        #expect(assessment.refundDue == Money(100))
    }

    @Test("A no-show charges the no-show percentage")
    func noShowChargesNoShowFee() {
        let assessment = assess(now: Fixtures.mondayAt(14, 30), trigger: .noShow)

        #expect(assessment.outcome == .noShow)
        #expect(assessment.feePercent == 100)
        #expect(assessment.fee == Money(200))
        #expect(assessment.refundDue == Money(0))
    }

    @Test("Cancelling after the appointment has begun is assessed as a no-show")
    func cancellingAfterStartIsANoShow() {
        let assessment = assess(now: Fixtures.mondayAt(14, 5))

        #expect(assessment.outcome == .noShow)
        #expect(assessment.feePercent == 100)
        #expect(assessment.minutesUntilStart == -5)
    }

    @Test("A salon-initiated cancellation is always free, however late")
    func salonCancellationIsAlwaysFree() {
        let assessment = assess(now: Fixtures.mondayAt(13, 55), trigger: .salonCancellation)

        #expect(assessment.outcome == .salonInitiated)
        #expect(assessment.isFree)
        #expect(assessment.refundDue == Money(200))
    }

    @Test("Fee and refund always add back up to the amount paid")
    func feeAndRefundReconcile() {
        let cases: [Date] = [
            Fixtures.date(2026, 2, 25, 9),
            Fixtures.date(2026, 3, 1, 14),
            Fixtures.date(2026, 3, 2, 9),
            Fixtures.mondayAt(14, 30),
        ]

        for now in cases {
            let assessment = assess(now: now)
            #expect(assessment.fee + assessment.refundDue == paid)
        }
    }

    @Test("A zero deposit produces zero money but still reports the policy percentage")
    func zeroDepositStillReportsPercent() {
        let assessment = engine.assess(
            policies: policies,
            appointmentStart: start,
            now: Fixtures.mondayAt(9),
            amountPaid: Money(0),
            trigger: .clientCancellation
        )

        #expect(assessment.feePercent == 50)
        #expect(!assessment.isFree)
        #expect(assessment.fee.isZero)
        #expect(assessment.refundDue.isZero)
    }

    @Test("An out-of-range policy percentage is clamped to 0...100")
    func percentagesAreClamped() {
        let absurd = SalonPolicies(
            freeCancellationHours: 24,
            lateCancellationFeePercent: 250,
            noShowFeePercent: -30
        )

        let late = engine.assess(
            policies: absurd,
            appointmentStart: start,
            now: Fixtures.mondayAt(9),
            amountPaid: paid
        )
        let noShow = engine.assess(
            policies: absurd,
            appointmentStart: start,
            now: Fixtures.mondayAt(9),
            amountPaid: paid,
            trigger: .noShow
        )

        #expect(late.feePercent == 100)
        #expect(late.fee == paid)
        #expect(noShow.feePercent == 0)
        #expect(noShow.refundDue == paid)
    }

    @Test("A zero-hour free window makes every cancellation free until the start")
    func zeroHourWindowIsAlwaysFree() {
        let relaxed = SalonPolicies(freeCancellationHours: 0, lateCancellationFeePercent: 50)
        let assessment = engine.assess(
            policies: relaxed,
            appointmentStart: start,
            now: Fixtures.mondayAt(13, 59),
            amountPaid: paid
        )

        #expect(assessment.outcome == .withinFreeWindow)
        #expect(assessment.isFree)
    }

    @Test("Percentages apply to the amount actually paid, not the full price")
    func feeIsProportionalToAmountPaid() {
        let deposit = engine.assess(
            policies: policies,
            appointmentStart: start,
            now: Fixtures.mondayAt(9),
            amountPaid: Money(90)
        )

        #expect(deposit.fee == Money(45))
        #expect(deposit.refundDue == Money(45))
    }

    @Test("The appointment overload reads the start from the appointment items")
    func appointmentOverloadUsesItemStart() throws {
        let appointment = Fixtures.appointment(
            start: Fixtures.mondayAt(14),
            minutes: 60,
            professionalID: Fixtures.proAID
        )
        let assessment = try #require(
            engine.assess(
                policies: policies,
                appointment: appointment,
                now: Fixtures.mondayAt(9),
                amountPaid: paid
            )
        )

        #expect(assessment.outcome == .lateCancellation)
        #expect(assessment.minutesUntilStart == 300)
    }

    @Test("An appointment with no items cannot be assessed")
    func appointmentWithoutItemsReturnsNil() {
        let empty = Appointment(
            salonID: Fixtures.salonID,
            salonName: "Fixture Salon",
            clientID: Fixtures.clientID,
            items: []
        )

        #expect(engine.assess(policies: policies, appointment: empty, now: Fixtures.mondayAt(9), amountPaid: paid) == nil)
    }

    @Test("The no-show threshold honours the salon's grace period")
    func noShowThresholdUsesGracePeriod() {
        let graceful = SalonPolicies(lateGraceMinutes: 15)

        #expect(engine.noShowThreshold(policies: graceful, appointmentStart: start) == Fixtures.mondayAt(14, 15))
    }
}
