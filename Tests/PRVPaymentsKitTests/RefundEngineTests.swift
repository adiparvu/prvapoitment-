import Foundation
import PRVModels
import PRVPaymentsKit
import Testing

@Suite("RefundEngine")
struct RefundEngineTests {
    private let engine = RefundEngine()
    private let orderID = Order.ID()

    @Test("A cancellation refunds what the fee left, automatically")
    func cancellationRefundsAfterFee() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(100), reason: .cancellation)

        #expect(decision.outcome == .automatic)
        #expect(decision.amount == Money(100))
        #expect(decision.retainedFee == Money(100))
        #expect(decision.isAutomatic)
        #expect(!decision.requiresApproval)
        #expect(decision.movesMoney)
    }

    @Test("A free-window cancellation returns everything")
    func freeCancellationRefundsEverything() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(0), reason: .cancellation)

        #expect(decision.outcome == .automatic)
        #expect(decision.amount == Money(200))
        #expect(decision.retainedFee == Money(0))
        #expect(decision.explanation.contains("free window"))
    }

    @Test("A fee that swallows the payment leaves nothing to refund")
    func fullFeeLeavesNothingToRefund() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(200), reason: .cancellation)

        #expect(decision.outcome == .nothingToRefund)
        #expect(decision.amount == Money(0))
        #expect(!decision.isAutomatic)
        #expect(!decision.requiresApproval)
        #expect(!decision.movesMoney)
        #expect(engine.makeRefund(orderID: orderID, decision: decision) == nil)
    }

    @Test("A fee larger than the payment is clamped, never inverted")
    func oversizedFeeIsClamped() {
        let decision = engine.decide(amountPaid: Money(50), cancellationFee: Money(500), reason: .cancellation)

        #expect(decision.retainedFee == Money(50))
        #expect(decision.amount == Money(0))
        #expect(decision.outcome == .nothingToRefund)
    }

    @Test("Nothing paid means nothing to refund, whatever the reason")
    func nothingPaidMeansNothingToRefund() {
        for reason in Refund.Reason.allCases {
            let decision = engine.decide(amountPaid: Money(0), cancellationFee: Money(0), reason: reason)
            #expect(decision.outcome == .nothingToRefund, "\(reason) should refund nothing")
            #expect(decision.amount == Money(0))
        }
    }

    @Test("Duplicate charges are returned in full, with no fee")
    func duplicateChargesIgnoreTheFee() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(100), reason: .duplicate)

        #expect(decision.outcome == .automatic)
        #expect(decision.amount == Money(200))
        #expect(decision.retainedFee == Money(0))
    }

    @Test("Service issues waive the fee but wait for a human")
    func serviceIssuesNeedApproval() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(100), reason: .serviceIssue)

        #expect(decision.outcome == .needsApproval)
        #expect(decision.amount == Money(200))
        #expect(decision.retainedFee == Money(0))
        #expect(decision.requiresApproval)
        #expect(!decision.isAutomatic)
    }

    @Test("Goodwill refunds keep the fee and wait for a human")
    func goodwillNeedsApproval() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(50), reason: .goodwill)

        #expect(decision.outcome == .needsApproval)
        #expect(decision.amount == Money(150))
        #expect(decision.retainedFee == Money(50))
    }

    @Test("Fraud always goes to the risk team")
    func fraudGoesToRiskReview() {
        let decision = engine.decide(amountPaid: Money(80), cancellationFee: Money(0), reason: .fraud)

        #expect(decision.outcome == .needsApproval)
        #expect(decision.amount == Money(80))
        #expect(decision.explanation.contains("fraud"))
    }

    @Test("Large refunds need a manager however routine the reason")
    func largeRefundsNeedApproval() {
        let decision = engine.decide(amountPaid: Money(400), cancellationFee: Money(0), reason: .cancellation)

        #expect(decision.outcome == .needsApproval)
        #expect(decision.amount == Money(400))
        #expect(decision.explanation.contains("manager"))
    }

    @Test("The automatic ceiling is inclusive")
    func ceilingIsInclusive() {
        let atCeiling = engine.decide(amountPaid: Money(250), cancellationFee: Money(0), reason: .cancellation)
        let overCeiling = engine.decide(
            amountPaid: Fixtures.eur("250.01"),
            cancellationFee: Money(0),
            reason: .cancellation
        )

        #expect(atCeiling.outcome == .automatic)
        #expect(overCeiling.outcome == .needsApproval)
    }

    @Test("A review-everything policy never issues an automatic refund")
    func alwaysReviewPolicyBlocksAutomation() {
        let strict = RefundEngine(policy: .alwaysReview)
        let decision = strict.decide(amountPaid: Money(20), cancellationFee: Money(0), reason: .cancellation)

        #expect(decision.outcome == .needsApproval)
        #expect(!decision.isAutomatic)
    }

    @Test("Every reason produces a decision that can never exceed what was paid")
    func decisionsNeverExceedThePayment() {
        let paid = Money(200)
        for reason in Refund.Reason.allCases {
            for fee in [Money(0), Money(50), Money(200), Money(500)] {
                let decision = engine.decide(amountPaid: paid, cancellationFee: fee, reason: reason)
                #expect(decision.amount.amount >= 0)
                #expect(decision.amount.amount <= paid.amount)
                #expect(decision.retainedFee.amount <= paid.amount)
                #expect((decision.amount + decision.retainedFee).amount <= paid.amount)
            }
        }
    }

    @Test("An order-level decision reads what the order recorded as paid")
    func decidesFromAnOrder() {
        var order = Order(
            salonID: Fixtures.salonID,
            clientID: Fixtures.clientID,
            lines: [OrderLine(kind: .service, title: "Balayage & Gloss", unitPrice: Money(185))],
            status: .paid
        )
        order.amountPaid = Money(185)

        let decision = engine.decide(order: order, cancellationFee: Fixtures.eur("92.50"), reason: .cancellation)

        #expect(decision.amount == Fixtures.eur("92.50"))
        #expect(decision.outcome == .automatic)
    }

    @Test("A materialized refund carries the decision onto the ledger")
    func materializedRefundCarriesTheDecision() {
        let decision = engine.decide(amountPaid: Money(200), cancellationFee: Money(100), reason: .cancellation)
        let refund = engine.makeRefund(orderID: orderID, decision: decision, createdAt: Fixtures.now)

        #expect(refund?.orderID == orderID)
        #expect(refund?.amount == Money(100))
        #expect(refund?.reason == .cancellation)
        #expect(refund?.isAutomatic == true)
        #expect(refund?.createdAt == Fixtures.now)
        #expect(refund?.note == decision.explanation)
    }
}
