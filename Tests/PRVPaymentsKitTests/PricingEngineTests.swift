import Foundation
import PRVModels
import PRVPaymentsKit
import Testing

@Suite("PricingEngine")
struct PricingEngineTests {
    private let engine = PricingEngine()

    // MARK: - Line building

    @Test("Services and add-ons expand into itemized lines")
    func linesItemizeAddOns() {
        let priced = engine.price(Fixtures.request())

        #expect(priced.lines.count == 2)
        #expect(priced.lines[0].title == "Balayage & Gloss")
        #expect(priced.lines[0].total == Money(185))
        #expect(priced.lines[1].title.contains("Olaplex"))
        #expect(priced.lines[1].total == Money(35))
        #expect(priced.itemsSubtotal == Money(220))
        #expect(priced.total == Money(220))
    }

    @Test("Quantity multiplies both the service and every add-on")
    func quantityMultipliesAddOns() {
        let item = PricingItem(
            title: "Cut & Blow-Dry",
            unitPrice: Money(75),
            quantity: 2,
            addOns: [PricingAddOn(name: "Scalp Massage", price: Money(25))]
        )
        let priced = engine.price(Fixtures.request(items: [item]))

        #expect(priced.lines.count == 2)
        #expect(priced.lines[0].quantity == 2)
        #expect(priced.lines[1].quantity == 2)
        #expect(priced.itemsSubtotal == Money(200))
        #expect(item.total == Money(200))
    }

    @Test("A zero-quantity item prices as absent")
    func zeroQuantityItemIsDropped() {
        let item = PricingItem(title: "Gloss", unitPrice: Money(40), quantity: 0)
        let priced = engine.price(Fixtures.request(items: [item]))

        #expect(priced.lines.isEmpty)
        #expect(priced.itemsSubtotal == Money(0))
        #expect(priced.total == Money(0))
    }

    // MARK: - VAT

    @Test("VAT is recovered from a VAT-inclusive total, never added on top")
    func vatIsInclusive() {
        let breakdown = VATBreakdown(gross: Money(121), ratePercent: 21)

        #expect(breakdown.gross == Money(121))
        #expect(breakdown.net == Money(100))
        #expect(breakdown.vat == Money(21))
    }

    @Test("VAT rounds with banker's rounding and always reconciles")
    func vatReconcilesExactly() {
        let grosses = [
            Money(220), Money(185), Fixtures.eur("0.01"), Fixtures.eur("99.99"),
            Fixtures.eur("1234.56"), Money(0),
        ]
        for gross in grosses {
            let breakdown = VATBreakdown(gross: gross, ratePercent: 21)
            #expect(breakdown.net + breakdown.vat == gross, "VAT split lost a cent on \(gross.formatted)")
            #expect(breakdown.vat.amount >= 0)
            #expect(breakdown.net.amount >= 0)
        }

        // 220 / 1.21 = 181.8181… → 181.82, leaving 38.18 of tax.
        let standard = VATBreakdown(gross: Money(220), ratePercent: 21)
        #expect(standard.net == Fixtures.eur("181.82"))
        #expect(standard.vat == Fixtures.eur("38.18"))
    }

    @Test("A zero VAT rate leaves the whole amount net")
    func zeroVATRate() {
        let breakdown = VATBreakdown(gross: Money(220), ratePercent: 0)

        #expect(breakdown.net == Money(220))
        #expect(breakdown.vat == Money(0))
        // The rate is formatted without trailing zeros; the amount is localized.
        #expect(breakdown.receiptNote.hasSuffix("VAT (0%)"))
        #expect(VATBreakdown(gross: Money(220), ratePercent: 21).receiptNote.hasSuffix("VAT (21%)"))
    }

    @Test("Tips are excluded from the VAT base")
    func tipsAreNotTaxed() {
        let priced = engine.price(Fixtures.request(tip: .percent(10)))

        #expect(priced.tip == Money(22))
        #expect(priced.total == Money(242))
        #expect(priced.vat.gross == Money(220))
        #expect(priced.vat.vat == Fixtures.eur("38.18"))
    }

    // MARK: - Coupons

    @Test("A percentage coupon reduces the subtotal")
    func percentageCoupon() {
        let priced = engine.price(
            Fixtures.request(coupon: Fixtures.coupon(discount: .percent(10), minimumSpend: Money(200)))
        )

        #expect(priced.couponEvaluation?.isApplicable == true)
        #expect(priced.totalDiscount == Money(22))
        #expect(priced.total == Money(198))
        #expect(priced.discountReason == "Code SPRING")
    }

    @Test("A coupon under its minimum spend is rejected and costs nothing")
    func couponBelowMinimumSpendIsRejected() {
        let priced = engine.price(
            Fixtures.request(coupon: Fixtures.coupon(discount: .percent(10), minimumSpend: Money(250)))
        )

        #expect(priced.couponEvaluation?.isApplicable == false)
        #expect(priced.couponEvaluation?.rejection == .belowMinimumSpend(Money(250)))
        #expect(priced.totalDiscount == Money(0))
        #expect(priced.total == Money(220))
    }

    @Test("Minimum spend is measured before other discounts apply")
    func minimumSpendIgnoresOtherDiscounts() {
        // A 15% membership takes €220 to €187, below the €200 minimum — but the
        // client still qualified when they added the code.
        let priced = engine.price(
            Fixtures.request(
                coupon: Fixtures.coupon(discount: .percent(10), minimumSpend: Money(200)),
                membershipDiscountPercent: 15
            )
        )

        #expect(priced.couponEvaluation?.isApplicable == true)
        #expect(priced.adjustments.count == 2)
        #expect(priced.adjustments[0].kind == .membership)
        #expect(priced.adjustments[0].amount == Money(33))
        #expect(priced.adjustments[1].kind == .coupon)
        #expect(priced.adjustments[1].amount == Fixtures.eur("18.70"))
        #expect(priced.total == Fixtures.eur("168.30"))
    }

    @Test("A fixed coupon can never take an order below zero")
    func fixedCouponClampsToSubtotal() {
        let priced = engine.price(Fixtures.request(coupon: Fixtures.coupon(discount: .fixed(Money(500)))))

        #expect(priced.totalDiscount == Money(220))
        #expect(priced.total == Money(0))
        #expect(priced.vat.vat == Money(0))
    }

    @Test("Invalid coupons are rejected with the reason the client sees")
    func invalidCouponsAreRejected() {
        let now = Fixtures.now
        let cases: [(Coupon, CouponEvaluation.Rejection)] = [
            (Fixtures.coupon(discount: .percent(10), isActive: false), .inactive),
            (
                Fixtures.coupon(discount: .percent(10), validFrom: Fixtures.date(2026, 4, 1)),
                .notYetValid(Fixtures.date(2026, 4, 1))
            ),
            (
                Fixtures.coupon(discount: .percent(10), validUntil: Fixtures.date(2026, 2, 1)),
                .expired(Fixtures.date(2026, 2, 1))
            ),
            (
                Fixtures.coupon(discount: .percent(10), maxRedemptions: 5, redemptionCount: 5),
                .exhausted
            ),
            (
                Fixtures.coupon(discount: .percent(10), salonID: PreviewData.salonVelvet.id),
                .wrongSalon
            ),
        ]

        for (coupon, expected) in cases {
            let evaluation = engine.evaluate(
                coupon: coupon,
                subtotal: Money(220),
                salonID: Fixtures.salonID,
                now: now
            )
            #expect(evaluation.rejection == expected)
            #expect(evaluation.discount == Money(0))
            #expect(!evaluation.rejection!.message.isEmpty)
        }
    }

    // MARK: - Memberships

    @Test("The membership hook reads the best discount off an active plan")
    func membershipHookReadsActivePlans() {
        #expect(PricingEngine.membershipDiscountPercent(for: Fixtures.subscription()) == 15)
        #expect(PricingEngine.membershipDiscountPercent(for: Fixtures.subscription(status: .cancelled)) == 0)
        #expect(PricingEngine.membershipDiscountPercent(for: Fixtures.subscription(status: .pastDue)) == 0)
        #expect(PricingEngine.membershipDiscountPercent(for: nil) == 0)
    }

    @Test("Gift cards are excluded from percentage discounts")
    func giftCardsAreNeverDiscounted() {
        let service = PricingItem(title: "Cut & Blow-Dry", unitPrice: Money(100))
        let giftCard = PricingItem(giftCardTitle: "Gift Card", faceValue: Money(50))
        let priced = engine.price(
            Fixtures.request(items: [service, giftCard], membershipDiscountPercent: 10)
        )

        #expect(priced.itemsSubtotal == Money(150))
        #expect(priced.totalDiscount == Money(10))
        #expect(priced.total == Money(140))
    }

    // MARK: - Prepayment

    @Test("Full prepayment discounts the order and settles it in one charge")
    func fullPrepaymentIsDiscounted() {
        let priced = engine.price(Fixtures.request(prepayment: .full))

        #expect(priced.totalDiscount == Money(22))
        #expect(priced.discountedSubtotal == Money(198))
        #expect(priced.total == Money(198))
        #expect(priced.amountDueNow == Money(198))
        #expect(priced.amountDueLater == Money(0))
        #expect(priced.prepaymentQuote.cashback == Fixtures.eur("3.96"))
        #expect(priced.pointsEarned == 396)
    }

    @Test("A deposit splits the order and carries the tip with the charge")
    func depositCarriesTheTip() {
        let priced = engine.price(Fixtures.request(prepayment: .twenty, tip: .percent(10)))

        #expect(priced.totalDiscount == Money(0))
        #expect(priced.tip == Money(22))
        #expect(priced.total == Money(242))
        #expect(priced.amountDueNow == Money(66))
        #expect(priced.amountDueLater == Money(176))
        #expect(priced.amountDueNow + priced.amountDueLater == priced.total)
    }

    @Test("Paying at the salon charges nothing now, tip included")
    func payAtSalonChargesNothingNow() {
        let priced = engine.price(Fixtures.request(tip: .amount(Money(15))))

        #expect(priced.tip == Money(15))
        #expect(priced.total == Money(235))
        #expect(priced.amountDueNow == Money(0))
        #expect(priced.amountDueLater == Money(235))
        #expect(priced.pointsEarned == 220)
    }

    // MARK: - Invariants & materialization

    @Test("Every priced order reconciles to the cent")
    func everyPricedOrderReconciles() {
        let requests: [PricingRequest] = [
            Fixtures.request(),
            Fixtures.request(coupon: Fixtures.coupon(discount: .percent(33)), membershipDiscountPercent: 7),
            Fixtures.request(prepayment: .thirty, tip: .percent(15)),
            Fixtures.request(prepayment: .full, tip: .amount(Fixtures.eur("12.37"))),
            Fixtures.request(
                items: [PricingItem(title: "Trim", unitPrice: Fixtures.eur("33.33"), quantity: 3)],
                prepayment: .fifty,
                tip: .percent(18)
            ),
        ]

        for request in requests {
            let priced = engine.price(request)
            #expect(priced.discountedSubtotal == priced.itemsSubtotal - priced.totalDiscount)
            #expect(priced.total == priced.discountedSubtotal + priced.tip)
            #expect(priced.amountDueNow + priced.amountDueLater == priced.total)
            #expect(priced.vat.net + priced.vat.vat == priced.vat.gross)
            #expect(priced.vat.gross == priced.discountedSubtotal)
            #expect(priced.totalDiscount.amount <= priced.itemsSubtotal.amount)
        }
    }

    @Test("The materialized order carries the same total as the pricing")
    func materializedOrderMatchesPricing() {
        let priced = engine.price(Fixtures.request(prepayment: .full, tip: .percent(10)))
        let order = priced.makeOrder(
            salonID: Fixtures.salonID,
            clientID: Fixtures.clientID,
            createdAt: Fixtures.now
        )

        #expect(priced.tip == Fixtures.eur("19.80"))
        #expect(order.subtotal == Fixtures.eur("239.80"))
        #expect(order.discount == Money(22))
        #expect(order.total == priced.total)
        #expect(order.total == Fixtures.eur("217.80"))
        #expect(order.outstandingBalance == order.total)
        #expect(order.vatPercent == 21)
        #expect(order.pointsEarned == priced.pointsEarned)
        #expect(order.status == .awaitingPayment)
    }

    @Test("Reward points are one per whole unit, multiplied when prepaid")
    func rewardPointsScaleWithPrepayment() {
        #expect(PricingEngine.points(for: Money(198), multiplier: 2) == 396)
        #expect(PricingEngine.points(for: Fixtures.eur("199.99"), multiplier: 1) == 199)
        #expect(PricingEngine.points(for: Money(0), multiplier: 5) == 0)
        #expect(PricingEngine.points(for: Money(50), multiplier: 0) == 50)
    }

    @Test("Percentages and amounts round with banker's rounding")
    func bankersRoundingOnHalfCents() {
        // 1.25 × 50% = 0.625 → 0.62; 1.75 × 50% = 0.875 → 0.88.
        #expect(Fixtures.eur("1.25").percentage(50) == Fixtures.eur("0.62"))
        #expect(Fixtures.eur("1.75").percentage(50) == Fixtures.eur("0.88"))
    }
}
