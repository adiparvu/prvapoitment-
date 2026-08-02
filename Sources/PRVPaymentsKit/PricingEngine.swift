import Foundation
import PRVFoundation
import PRVModels

// MARK: - Inputs

/// An add-on the client chose alongside a service.
public struct PricingAddOn: Hashable, Sendable, Identifiable {
    public typealias ID = ServiceAddOn.ID

    /// The catalogue add-on this line came from.
    public var id: ID
    /// Display name, e.g. "Olaplex Treatment".
    public var name: String
    /// Price for one unit of the add-on.
    public var price: Money
    /// How many of this add-on were chosen, per unit of the parent item.
    public var quantity: Int

    /// Creates an add-on line.
    public init(id: ID = ID(), name: String, price: Money, quantity: Int = 1) {
        self.id = id
        self.name = name
        self.price = price
        self.quantity = quantity
    }

    /// Creates an add-on line from a catalogue ``ServiceAddOn``.
    public init(_ addOn: ServiceAddOn, quantity: Int = 1) {
        self.init(id: addOn.id, name: addOn.name, price: addOn.price, quantity: quantity)
    }

    /// Quantity floored at zero — a negative quantity prices as absent.
    public var effectiveQuantity: Int { Swift.max(0, quantity) }

    /// Price of this add-on for one unit of its parent item.
    public var total: Money { price * Decimal(effectiveQuantity) }
}

/// One priceable thing on an order: a service, a product, a membership, a
/// package, or a gift card — with the add-ons and quantity chosen for it.
public struct PricingItem: Hashable, Sendable, Identifiable {
    /// Stable identity for diffing in UI; not persisted.
    public var id: UUID
    /// Which kind of order line this item becomes.
    public var kind: OrderLine.Kind
    /// Display title, e.g. "Balayage & Gloss".
    public var title: String
    /// Price for one unit, before add-ons.
    public var unitPrice: Money
    /// How many units were booked.
    public var quantity: Int
    /// Add-ons attached to each unit of this item.
    public var addOns: [PricingAddOn]
    /// The catalogue entity this item came from (service, product, plan…).
    public var referenceID: UUID?
    /// Whether percentage discounts (memberships, coupons) apply here.
    /// Gift cards and deposits are never discounted — selling €100 of stored
    /// value for €90 would be a loss, not a promotion.
    public var isDiscountable: Bool

    /// Creates a priced item.
    public init(
        id: UUID = UUID(),
        kind: OrderLine.Kind = .service,
        title: String,
        unitPrice: Money,
        quantity: Int = 1,
        addOns: [PricingAddOn] = [],
        referenceID: UUID? = nil,
        isDiscountable: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.unitPrice = unitPrice
        self.quantity = quantity
        self.addOns = addOns
        self.referenceID = referenceID
        self.isDiscountable = isDiscountable
    }

    /// Prices a catalogue service with the add-ons the client selected.
    public init(service: SalonService, quantity: Int = 1, addOns: [ServiceAddOn] = []) {
        self.init(
            kind: .service,
            title: service.name,
            unitPrice: service.price,
            quantity: quantity,
            addOns: addOns.map { PricingAddOn($0) },
            referenceID: service.id.rawValue
        )
    }

    /// Prices a gift card, which is excluded from percentage discounts.
    public init(giftCardTitle: String, faceValue: Money, quantity: Int = 1) {
        self.init(
            kind: .giftCard,
            title: giftCardTitle,
            unitPrice: faceValue,
            quantity: quantity,
            isDiscountable: false
        )
    }

    /// Quantity floored at zero — a negative quantity prices as absent.
    public var effectiveQuantity: Int { Swift.max(0, quantity) }

    /// Price of the item itself, excluding add-ons.
    public var baseTotal: Money { unitPrice * Decimal(effectiveQuantity) }

    /// Price of every add-on across every unit of this item.
    public var addOnsTotal: Money {
        addOns.reduce(Money.zero(unitPrice.currency)) { running, addOn in
            running + Money(addOn.total.amount, unitPrice.currency) * Decimal(effectiveQuantity)
        }
    }

    /// Everything this item contributes to the subtotal.
    public var total: Money { baseTotal + addOnsTotal }
}

/// How the client chose to tip.
public enum Tip: Hashable, Sendable {
    /// No tip.
    case none
    /// A percentage (0–100) of the discounted service total.
    case percent(Decimal)
    /// An exact amount typed by the client.
    case amount(Money)

    /// Resolves the tip against the amount it is calculated from.
    /// Percentages are banker's-rounded to cents; negatives resolve to zero.
    public func resolved(on base: Money) -> Money {
        switch self {
        case .none:
            return .zero(base.currency)
        case .percent(let percent):
            return MoneyMath.clampedToZero(base.percentage(Swift.max(0, percent)))
        case .amount(let money):
            return MoneyMath.clampedToZero(MoneyMath.denominated(money, in: base.currency))
        }
    }

    /// Whether this tip contributes anything.
    public var isNone: Bool {
        switch self {
        case .none: true
        case .percent(let percent): percent <= 0
        case .amount(let money): money.amount <= 0
        }
    }
}

// MARK: - VAT

/// A VAT split derived from a **VAT-inclusive** gross amount, EU style.
///
/// Prices in PRV are displayed and charged tax-inclusive, so the net is
/// recovered by dividing rather than multiplying:
/// `net = gross / (1 + rate)`, `vat = gross − net`.
/// Deriving VAT by subtraction (instead of rounding it independently)
/// guarantees `net + vat == gross` to the cent, always.
public struct VATBreakdown: Hashable, Sendable {
    /// The rate applied, as a percentage (e.g. `21` for Belgium).
    public let ratePercent: Decimal
    /// The VAT-inclusive amount the client pays.
    public let gross: Money
    /// The amount excluding VAT.
    public let net: Money
    /// The tax contained in `gross`.
    public let vat: Money

    /// Splits a VAT-inclusive amount at the given rate.
    /// - Parameters:
    ///   - gross: The tax-inclusive amount; negatives clamp to zero.
    ///   - ratePercent: VAT rate as a percentage; negatives clamp to zero.
    public init(gross: Money, ratePercent: Decimal) {
        let rate = Swift.max(0, ratePercent)
        let grossAmount = Swift.max(0, gross.amount)
        let divisor = 1 + rate / 100
        let netAmount = divisor > 0 ? MoneyMath.rounded(grossAmount / divisor) : grossAmount

        self.ratePercent = rate
        self.gross = Money(grossAmount, gross.currency)
        self.net = Money(netAmount, gross.currency)
        self.vat = Money(grossAmount - netAmount, gross.currency)
    }

    /// A human line for receipts, e.g. `"Includes €34.09 VAT (21%)"`.
    public var receiptNote: String {
        "Includes \(vat.formatted) VAT (\(ratePercent.formattedPercent))"
    }
}

// MARK: - Adjustments

/// One reduction applied to an order, kept separate so a receipt can show
/// exactly why the price moved.
public struct PriceAdjustment: Hashable, Sendable, Identifiable {
    /// What granted the reduction.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case membership
        case coupon
        case prepayment
    }

    /// What granted the reduction.
    public let kind: Kind
    /// Receipt label, e.g. `"Code SPRING20"`.
    public let label: String
    /// A positive amount, subtracted from the subtotal.
    public let amount: Money

    /// Creates an adjustment.
    public init(kind: Kind, label: String, amount: Money) {
        self.kind = kind
        self.label = label
        self.amount = amount
    }

    public var id: String { "\(kind.rawValue)|\(label)" }
}

/// The outcome of testing a coupon against an order.
public struct CouponEvaluation: Hashable, Sendable {
    /// Why a coupon could not be applied.
    public enum Rejection: Hashable, Sendable {
        case inactive
        case notYetValid(Date)
        case expired(Date)
        case exhausted
        case wrongSalon
        case belowMinimumSpend(Money)

        /// Client-facing explanation.
        public var message: String {
            switch self {
            case .inactive: "This code is no longer active."
            case .notYetValid(let date):
                "This code starts on \(date.formatted(date: .abbreviated, time: .omitted))."
            case .expired: "This code has expired."
            case .exhausted: "This code has been fully redeemed."
            case .wrongSalon: "This code belongs to another salon."
            case .belowMinimumSpend(let minimum):
                "Spend \(minimum.formatted) to use this code."
            }
        }
    }

    /// The code that was tested, upper-cased.
    public let code: String
    /// The reduction the coupon grants — zero when it was rejected.
    public let discount: Money
    /// Why the coupon was rejected, or `nil` when it applies.
    public let rejection: Rejection?

    /// Creates an evaluation.
    public init(code: String, discount: Money, rejection: Rejection? = nil) {
        self.code = code
        self.discount = discount
        self.rejection = rejection
    }

    /// Whether the coupon passed every rule.
    public var isApplicable: Bool { rejection == nil }
}

// MARK: - Request

/// Everything needed to price one order.
public struct PricingRequest: Hashable, Sendable {
    /// Items being bought.
    public var items: [PricingItem]
    /// A promo code the client entered, if any.
    public var coupon: Coupon?
    /// Salon the coupon must belong to, when it should be checked.
    public var salonID: Salon.ID?
    /// Membership discount hook: a percentage (0–100) granted by the client's
    /// active plan. Resolve it with ``PricingEngine/membershipDiscountPercent(for:)``.
    public var membershipDiscountPercent: Decimal
    /// Receipt label for the membership reduction.
    public var membershipLabel: String
    /// Prepayment level the client picked, or `nil` for "pay at the salon".
    public var prepayment: PrepaymentPolicy.Percent?
    /// The salon's prepayment incentives.
    public var prepaymentPolicy: PrepaymentPolicy
    /// The tip added at checkout.
    public var tip: Tip
    /// VAT rate contained in the displayed prices.
    public var vatPercent: Decimal
    /// Currency every line is denominated in.
    public var currency: Currency
    /// The instant used for coupon validity — injected, never `Date.now`
    /// inside the engine, so pricing is deterministic.
    public var now: Date

    /// Creates a pricing request.
    public init(
        items: [PricingItem],
        coupon: Coupon? = nil,
        salonID: Salon.ID? = nil,
        membershipDiscountPercent: Decimal = 0,
        membershipLabel: String = "Membership discount",
        prepayment: PrepaymentPolicy.Percent? = nil,
        prepaymentPolicy: PrepaymentPolicy = PrepaymentPolicy(),
        tip: Tip = .none,
        vatPercent: Decimal = 21,
        currency: Currency = .eur,
        now: Date = .now
    ) {
        self.items = items
        self.coupon = coupon
        self.salonID = salonID
        self.membershipDiscountPercent = membershipDiscountPercent
        self.membershipLabel = membershipLabel
        self.prepayment = prepayment
        self.prepaymentPolicy = prepaymentPolicy
        self.tip = tip
        self.vatPercent = vatPercent
        self.currency = currency
        self.now = now
    }
}

// MARK: - Result

/// A fully priced order: every line, every reduction, the tax split, and what
/// is due when.
///
/// Invariants, all exact in `Decimal`:
/// - `discountedSubtotal == itemsSubtotal − totalDiscount`
/// - `total == discountedSubtotal + tip`
/// - `amountDueNow + amountDueLater == total`
/// - `vat.net + vat.vat == vat.gross`
public struct PricedOrder: Hashable, Sendable {
    /// Currency of every amount below.
    public let currency: Currency
    /// Order lines, including the tip line when the client tipped.
    public let lines: [OrderLine]
    /// Sum of every item and add-on, before any reduction.
    public let itemsSubtotal: Money
    /// Each reduction, in the order it was applied.
    public let adjustments: [PriceAdjustment]
    /// Sum of every reduction, never more than `itemsSubtotal`.
    public let totalDiscount: Money
    /// `itemsSubtotal` after reductions — the taxable amount.
    public let discountedSubtotal: Money
    /// The tip, which is never discounted and never taxed.
    public let tip: Money
    /// What the client owes in total.
    public let total: Money
    /// The VAT contained in `discountedSubtotal`.
    public let vat: VATBreakdown
    /// Charged at checkout (prepayment plus any tip).
    public let amountDueNow: Money
    /// Settled at the salon on the day.
    public let amountDueLater: Money
    /// Reward points this order earns.
    public let pointsEarned: Int
    /// The outcome of the coupon, when one was supplied.
    public let couponEvaluation: CouponEvaluation?
    /// The prepayment consequences of the chosen level.
    public let prepaymentQuote: PrepaymentQuote

    /// Creates a priced order. Built by ``PricingEngine/price(_:)``; the
    /// memberwise initializer is public so callers can construct fixtures.
    public init(
        currency: Currency,
        lines: [OrderLine],
        itemsSubtotal: Money,
        adjustments: [PriceAdjustment],
        totalDiscount: Money,
        discountedSubtotal: Money,
        tip: Money,
        total: Money,
        vat: VATBreakdown,
        amountDueNow: Money,
        amountDueLater: Money,
        pointsEarned: Int,
        couponEvaluation: CouponEvaluation?,
        prepaymentQuote: PrepaymentQuote
    ) {
        self.currency = currency
        self.lines = lines
        self.itemsSubtotal = itemsSubtotal
        self.adjustments = adjustments
        self.totalDiscount = totalDiscount
        self.discountedSubtotal = discountedSubtotal
        self.tip = tip
        self.total = total
        self.vat = vat
        self.amountDueNow = amountDueNow
        self.amountDueLater = amountDueLater
        self.pointsEarned = pointsEarned
        self.couponEvaluation = couponEvaluation
        self.prepaymentQuote = prepaymentQuote
    }

    /// Human summary of every reduction, e.g. `"Membership discount, Code SPRING20"`.
    public var discountReason: String? {
        guard !adjustments.isEmpty else { return nil }
        return adjustments.map(\.label).joined(separator: ", ")
    }

    /// Materializes this pricing as a persistable ``Order``.
    /// - Parameters:
    ///   - salonID: Salon the order belongs to.
    ///   - clientID: Client being charged.
    ///   - appointmentID: Visit this order settles, when there is one.
    ///   - status: Initial status; defaults to awaiting payment.
    ///   - createdAt: Creation timestamp, injected for determinism.
    public func makeOrder(
        salonID: Salon.ID,
        clientID: User.ID,
        appointmentID: Appointment.ID? = nil,
        status: OrderStatus = .awaitingPayment,
        createdAt: Date = .now
    ) -> Order {
        Order(
            salonID: salonID,
            clientID: clientID,
            appointmentID: appointmentID,
            lines: lines,
            status: status,
            discount: totalDiscount,
            discountReason: discountReason,
            vatPercent: vat.ratePercent,
            amountPaid: .zero(currency),
            pointsEarned: pointsEarned,
            currency: currency,
            createdAt: createdAt
        )
    }
}

// MARK: - Engine

/// Prices an order from services, add-ons, quantities, and the incentives the
/// client is entitled to.
///
/// The engine is a pure function of its input — no clock, no I/O, no shared
/// state — so the client, the salon terminal, and the server can all run it
/// and always land on the same cent.
///
/// Reductions are applied in a fixed, documented order:
/// 1. **Membership** — a percentage off the discountable items.
/// 2. **Coupon** — evaluated against the *undiscounted* subtotal for its
///    minimum-spend test, then applied to what the membership left.
/// 3. **Prepayment** — the salon's full-prepayment discount, applied to what
///    remains, so incentives stack without ever compounding into a negative.
///
/// The tip is added afterwards: it is never discounted and never taxed.
public struct PricingEngine: Sendable {
    /// Creates an engine.
    public init() {}

    // MARK: Pricing

    /// Prices a request end to end.
    public func price(_ request: PricingRequest) -> PricedOrder {
        let currency = request.currency
        let zero = Money.zero(currency)

        var orderLines = lines(for: request.items, currency: currency)
        let itemsSubtotal = orderLines.reduce(zero) { $0 + $1.total }
        let discountableBase = request.items
            .filter(\.isDiscountable)
            .reduce(zero) { $0 + MoneyMath.denominated($1.total, in: currency) }

        var adjustments: [PriceAdjustment] = []

        // 1. Membership.
        let membershipPercent = MoneyMath.clampPercent(request.membershipDiscountPercent)
        let membershipDiscount = membershipPercent > 0
            ? MoneyMath.lesser(discountableBase.percentage(membershipPercent), discountableBase)
            : zero
        if !membershipDiscount.isZero {
            adjustments.append(
                PriceAdjustment(kind: .membership, label: request.membershipLabel, amount: membershipDiscount)
            )
        }

        // 2. Coupon.
        let couponBase = MoneyMath.clampedToZero(discountableBase - membershipDiscount)
        var couponEvaluation: CouponEvaluation?
        var couponDiscount = zero
        if let coupon = request.coupon {
            let evaluation = evaluate(
                coupon: coupon,
                subtotal: itemsSubtotal,
                discountableBase: couponBase,
                salonID: request.salonID,
                now: request.now
            )
            couponEvaluation = evaluation
            couponDiscount = evaluation.discount
            if !couponDiscount.isZero {
                adjustments.append(
                    PriceAdjustment(
                        kind: .coupon,
                        label: "Code \(evaluation.code)",
                        amount: couponDiscount
                    )
                )
            }
        }

        // 3. Prepayment.
        let prepaymentBase = MoneyMath.clampedToZero(itemsSubtotal - membershipDiscount - couponDiscount)
        let quote = PrepaymentCalculator().quote(
            policy: request.prepaymentPolicy,
            percent: request.prepayment,
            orderTotal: prepaymentBase
        )
        if !quote.discount.isZero {
            adjustments.append(
                PriceAdjustment(kind: .prepayment, label: "Prepayment discount", amount: quote.discount)
            )
        }

        let rawDiscount = membershipDiscount + couponDiscount + quote.discount
        let totalDiscount = MoneyMath.lesser(rawDiscount, itemsSubtotal)
        let discountedSubtotal = MoneyMath.clampedToZero(itemsSubtotal - totalDiscount)

        // 4. Tip, tax, and what is due when.
        let tip = request.tip.resolved(on: discountedSubtotal)
        if !tip.isZero {
            orderLines.append(OrderLine(kind: .tip, title: "Tip", unitPrice: tip))
        }
        let total = discountedSubtotal + tip
        let vat = vatBreakdown(gross: discountedSubtotal, ratePercent: request.vatPercent)

        // A tip is settled with whatever payment the client makes now; when
        // nothing is prepaid there is no "now", so it travels with the balance.
        let amountDueNow = request.prepayment == nil
            ? zero
            : MoneyMath.lesser(quote.payNow + tip, total)
        let amountDueLater = MoneyMath.clampedToZero(total - amountDueNow)

        return PricedOrder(
            currency: currency,
            lines: orderLines,
            itemsSubtotal: itemsSubtotal,
            adjustments: adjustments,
            totalDiscount: totalDiscount,
            discountedSubtotal: discountedSubtotal,
            tip: tip,
            total: total,
            vat: vat,
            amountDueNow: amountDueNow,
            amountDueLater: amountDueLater,
            pointsEarned: Self.points(for: discountedSubtotal, multiplier: quote.pointsMultiplier),
            couponEvaluation: couponEvaluation,
            prepaymentQuote: quote
        )
    }

    /// Expands items into order lines: one line per item, plus one line per
    /// add-on so the receipt itemizes exactly what the client agreed to.
    public func lines(for items: [PricingItem], currency: Currency) -> [OrderLine] {
        items.flatMap { item -> [OrderLine] in
            let quantity = item.effectiveQuantity
            guard quantity > 0 else { return [] }

            var result = [
                OrderLine(
                    kind: item.kind,
                    title: item.title,
                    quantity: quantity,
                    unitPrice: MoneyMath.denominated(item.unitPrice, in: currency),
                    referenceID: item.referenceID
                ),
            ]
            for addOn in item.addOns where addOn.effectiveQuantity > 0 {
                result.append(
                    OrderLine(
                        kind: item.kind,
                        title: "\(item.title) · \(addOn.name)",
                        quantity: quantity * addOn.effectiveQuantity,
                        unitPrice: MoneyMath.denominated(addOn.price, in: currency),
                        referenceID: addOn.id.rawValue
                    )
                )
            }
            return result
        }
    }

    // MARK: Coupons

    /// Tests a coupon against an order.
    ///
    /// The minimum-spend test always runs against the **undiscounted**
    /// subtotal: a client who qualified for "€20 off over €150" does not lose
    /// the code because a membership already took them under €150.
    ///
    /// - Parameters:
    ///   - coupon: The coupon to test.
    ///   - subtotal: Undiscounted order subtotal, used for minimum spend.
    ///   - discountableBase: The amount the reduction is calculated on;
    ///     defaults to `subtotal`.
    ///   - salonID: Salon being paid, when ownership should be enforced.
    ///   - now: The instant to validate against.
    public func evaluate(
        coupon: Coupon,
        subtotal: Money,
        discountableBase: Money? = nil,
        salonID: Salon.ID? = nil,
        now: Date
    ) -> CouponEvaluation {
        let code = coupon.code.trimmed.uppercased()
        let base = MoneyMath.clampedToZero(discountableBase ?? subtotal)
        let zero = Money.zero(base.currency)

        func rejected(_ rejection: CouponEvaluation.Rejection) -> CouponEvaluation {
            CouponEvaluation(code: code, discount: zero, rejection: rejection)
        }

        guard coupon.isActive else { return rejected(.inactive) }
        if now < coupon.validFrom { return rejected(.notYetValid(coupon.validFrom)) }
        if let validUntil = coupon.validUntil, now > validUntil { return rejected(.expired(validUntil)) }
        if let maximum = coupon.maxRedemptions, coupon.redemptionCount >= maximum {
            return rejected(.exhausted)
        }
        if let salonID, coupon.salonID != salonID { return rejected(.wrongSalon) }
        if let minimum = coupon.minimumSpend,
           subtotal.amount < MoneyMath.denominated(minimum, in: subtotal.currency).amount {
            return rejected(.belowMinimumSpend(MoneyMath.denominated(minimum, in: base.currency)))
        }

        let raw: Money = switch coupon.discount {
        case .percent(let percent):
            base.percentage(MoneyMath.clampPercent(Decimal(percent)))
        case .fixed(let money):
            MoneyMath.clampedToZero(MoneyMath.denominated(money, in: base.currency))
        }

        return CouponEvaluation(code: code, discount: MoneyMath.lesser(raw, base), rejection: nil)
    }

    // MARK: VAT

    /// Splits a VAT-inclusive amount into net and tax.
    public func vatBreakdown(gross: Money, ratePercent: Decimal) -> VATBreakdown {
        VATBreakdown(gross: gross, ratePercent: ratePercent)
    }

    // MARK: Hooks

    /// The membership discount hook: the best percentage an active
    /// subscription grants, or `0` when there is none.
    ///
    /// Only `.active` subscriptions count; a past-due or cancelled plan gives
    /// no discount, and the strongest `discountPercent` benefit wins when a
    /// plan carries several.
    public static func membershipDiscountPercent(for subscription: MembershipSubscription?) -> Decimal {
        guard let subscription, subscription.status == .active, let plan = subscription.plan else { return 0 }
        let best = plan.benefits
            .filter { $0.kind == .discountPercent }
            .compactMap(\.value)
            .max() ?? 0
        return Decimal(MoneyMath.clampPercent(best))
    }

    /// Reward points earned on an amount: one point per whole unit of
    /// currency, multiplied by the prepayment multiplier.
    public static func points(for amount: Money, multiplier: Int) -> Int {
        let whole = MoneyMath.wholeNumber(MoneyMath.floored(Swift.max(0, amount.amount)))
        return whole * Swift.max(1, multiplier)
    }
}

// MARK: - Formatting

extension Decimal {
    /// Formats a rate as a compact percentage, e.g. `21` → `"21%"`,
    /// `6.5` → `"6.5%"`.
    var formattedPercent: String {
        let rounded = self.rounded(scale: 2)
        let whole = MoneyMath.floored(rounded)
        let text = rounded == whole
            ? "\(MoneyMath.wholeNumber(whole))"
            : "\(rounded)"
        return "\(text)%"
    }
}
