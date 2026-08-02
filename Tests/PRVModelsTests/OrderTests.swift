import Foundation
import PRVModels
import Testing

@Suite("Order totals")
struct OrderTests {
    private func order(
        lines: [OrderLine],
        discount: Money = .zero(),
        amountPaid: Money = .zero(),
        currency: Currency = .eur
    ) -> Order {
        Order(
            salonID: ModelFixtures.salonID,
            clientID: ModelFixtures.clientID,
            lines: lines,
            discount: discount,
            amountPaid: amountPaid,
            currency: currency,
            createdAt: ModelFixtures.reference
        )
    }

    private var standardLines: [OrderLine] {
        [
            OrderLine(kind: .service, title: "Balayage & Gloss", quantity: 1, unitPrice: Money(185)),
            OrderLine(kind: .product, title: "Bond Shampoo", quantity: 2, unitPrice: Money(32)),
        ]
    }

    @Test("A line total is unit price times quantity")
    func lineTotalMultipliesByQuantity() {
        let line = OrderLine(kind: .product, title: "Bond Shampoo", quantity: 3, unitPrice: ModelFixtures.money("31.50"))

        #expect(line.total == ModelFixtures.money("94.50"))
        #expect(OrderLine(kind: .tip, title: "Tip", quantity: 1, unitPrice: Money(10)).total == Money(10))
    }

    @Test("Subtotal sums every line before any discount")
    func subtotalSumsLines() {
        #expect(order(lines: standardLines).subtotal == Money(249))
    }

    @Test("Total applies the discount to the subtotal")
    func totalAppliesDiscount() {
        let discounted = order(lines: standardLines, discount: Money(24))

        #expect(discounted.subtotal == Money(249))
        #expect(discounted.total == Money(225))
    }

    @Test("A discount larger than the subtotal floors the total at zero, never negative")
    func oversizedDiscountsFloorAtZero() {
        let overDiscounted = order(lines: standardLines, discount: Money(400))

        #expect(overDiscounted.total.isZero)
        #expect(overDiscounted.total.amount == 0)
        #expect(overDiscounted.outstandingBalance.isZero)
    }

    @Test("Outstanding balance is what is still owed after partial payment")
    func outstandingBalanceTracksPartialPayment() {
        let partiallyPaid = order(lines: standardLines, discount: Money(24), amountPaid: Money(100))

        #expect(partiallyPaid.total == Money(225))
        #expect(partiallyPaid.outstandingBalance == Money(125))
    }

    @Test("Overpayment never produces a negative balance owed")
    func overpaymentFloorsAtZero() {
        let overpaid = order(lines: standardLines, amountPaid: Money(500))

        #expect(overpaid.outstandingBalance.isZero)
    }

    @Test("A fully paid order owes nothing")
    func fullPaymentClearsTheBalance() {
        let paid = order(lines: standardLines, discount: Money(49), amountPaid: Money(200))

        #expect(paid.total == Money(200))
        #expect(paid.outstandingBalance.isZero)
    }

    @Test("An empty order is zero in its own currency, not in euros")
    func emptyOrderKeepsItsCurrency() {
        let empty = order(lines: [], currency: .usd)

        #expect(empty.subtotal == Money.zero(.usd))
        #expect(empty.subtotal.currency == .usd)
        #expect(empty.total.currency == .usd)
        #expect(empty.outstandingBalance.currency == .usd)
    }

    @Test("Mixed line kinds — tips and fees — all count toward the subtotal")
    func mixedLineKindsCount() {
        let withExtras = order(lines: standardLines + [
            OrderLine(kind: .tip, title: "Tip", quantity: 1, unitPrice: Money(20)),
            OrderLine(kind: .fee, title: "Late fee", quantity: 1, unitPrice: ModelFixtures.money("7.50")),
        ])

        #expect(withExtras.subtotal == ModelFixtures.money("276.50"))
    }

    @Test("Default order state is a draft with no discount and nothing paid")
    func defaultsAreSafe() {
        let draft = Order(salonID: ModelFixtures.salonID, clientID: ModelFixtures.clientID)

        #expect(draft.status == .draft)
        #expect(draft.discount.isZero)
        #expect(draft.amountPaid.isZero)
        #expect(draft.pointsEarned == 0)
        #expect(draft.vatPercent == 21)
        #expect(draft.currency == .eur)
        #expect(draft.paidAt == nil)
        #expect(draft.subtotal.isZero)
    }
}
