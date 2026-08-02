import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVPaymentsKit

// MARK: - Supporting choices

/// A way to pay presented in the checkout list.
enum CheckoutPaymentOption: Hashable, Identifiable, Sendable {
    /// The dedicated Apple Pay row, always first when the device supports it.
    case applePay
    /// A method the client has vaulted with Stripe.
    case saved(SavedPaymentMethod)

    var id: String {
        switch self {
        case .applePay: "apple-pay"
        case .saved(let method): method.id.description
        }
    }

    /// The kind sent to `PaymentRepository.pay(orderID:method:amount:)`.
    var kind: PaymentMethodKind {
        switch self {
        case .applePay: .applePay
        case .saved(let method): method.kind
        }
    }

    var title: String {
        switch self {
        case .applePay: "Apple Pay"
        case .saved(let method): method.displayLabel
        }
    }

    var subtitle: String? {
        switch self {
        case .applePay: "Double-click to confirm"
        case .saved(let method): PaymentsFormatting.methodSubtitle(method)
        }
    }

    var symbolName: String {
        switch self {
        case .applePay: PaymentMethodKind.applePay.symbolName
        case .saved(let method): method.kind.symbolName
        }
    }
}

/// The tip the client chose at checkout.
enum TipChoice: Hashable, Identifiable, Sendable {
    case none
    case percent(Int)
    case custom

    /// The chips offered, in order.
    static let options: [TipChoice] = [.none, .percent(5), .percent(10), .percent(15), .percent(20), .custom]

    var id: String {
        switch self {
        case .none: "none"
        case .percent(let value): "percent-\(value)"
        case .custom: "custom"
        }
    }

    var title: String {
        switch self {
        case .none: "No tip"
        case .percent(let value): "\(value)%"
        case .custom: "Other"
        }
    }
}

/// How much of the outstanding balance the client is settling now.
enum CheckoutAmountChoice: String, Hashable, CaseIterable, Sendable {
    case full
    case deposit

    var title: String {
        switch self {
        case .full: "Pay in full"
        case .deposit: "Pay deposit"
        }
    }
}

/// The result of a completed payment, used to render the success state.
struct CheckoutReceipt: Hashable, Sendable {
    /// The order as the backend returned it after the charge.
    var order: Order
    /// What was actually charged across every method used.
    var charged: Money
    /// Wallet cashback the salon's prepayment policy grants on this payment.
    var cashback: Money
    /// Reward points this order earned.
    var points: Int
    /// The invoice, once the backend has issued one.
    var invoice: Invoice?
    /// The gift card that contributed, when one was redeemed.
    var giftCardCode: String?
}

// MARK: - Model

/// Screen model backing ``CheckoutView``.
///
/// Owns the whole payment lifecycle: loading the order and the ways to pay,
/// recomputing the total as the client tips or switches to a deposit, applying
/// gift-card and store-credit balances, and finally charging — credits first,
/// remainder on the chosen method — so the ledger mirrors what the client saw.
///
/// All money arithmetic goes through `PRVPaymentsKit`, so the figure on the
/// button is the figure the pricing engine, the salon terminal, and the
/// backend all compute.
@Observable
@MainActor
final class CheckoutModel {
    /// Lifecycle of the initial load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// Lifecycle of the charge itself.
    enum PaymentPhase: Equatable, Sendable {
        case idle
        /// A charge is in flight; the string describes the current step.
        case processing(String)
        case succeeded(CheckoutReceipt)
        case failed(String)

        var isProcessing: Bool {
            if case .processing = self { return true }
            return false
        }

        var receipt: CheckoutReceipt? {
            if case .succeeded(let receipt) = self { return receipt }
            return nil
        }
    }

    /// The order being settled.
    let orderID: Order.ID

    private(set) var phase: Phase = .loading
    private(set) var paymentPhase: PaymentPhase = .idle
    private(set) var order: Order?
    private(set) var salon: Salon?
    private(set) var savedMethods: [SavedPaymentMethod] = []
    private(set) var storeCreditBalance: Money = .zero()
    private(set) var appliedGiftCard: GiftCard?
    private(set) var isApplePayAvailable = ApplePayCoordinator.isAvailable

    /// The method the client will be charged on.
    var selectedOption: CheckoutPaymentOption?
    /// The tip chip currently selected.
    var tipChoice: TipChoice = .none
    /// Free-typed tip amount, used when ``tipChoice`` is `.custom`.
    var customTipText = ""
    /// Whether the client is settling everything or leaving a balance.
    var amountChoice: CheckoutAmountChoice = .full
    /// Whether the client's store credit is being spent on this payment.
    var usesStoreCredit = false
    /// Whether the gift-card sheet is presented.
    var isRedeemingGiftCard = false
    /// Transient feedback (credit applied, redemption failed, …).
    var toast: PRVToast?

    private let pricing = PricingEngine()
    private let prepayment = PrepaymentCalculator()
    private let planner = PaymentPlanner()
    private let applePay = ApplePayCoordinator()

    /// Creates the model for one order.
    init(orderID: Order.ID) {
        self.orderID = orderID
    }

    // MARK: - Loading

    /// Loads the order, the salon behind it, the client's saved methods, and
    /// their store-credit balance — concurrently. Safe to call again to retry.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            phase = .failed("Sign in to complete this payment.")
            return
        }
        phase = .loading
        do {
            let order = try await deps.payments.order(id: orderID)
            self.order = order

            async let salonTask = deps.salons.salon(id: order.salonID)
            async let methodsTask = deps.payments.savedMethods(userID: user.id)
            async let creditTask = deps.payments.storeCreditBalance(userID: user.id)

            salon = try? await salonTask
            savedMethods = ((try? await methodsTask) ?? []).filter { $0.kind != .applePay }
            storeCreditBalance = clampedToZero((try? await creditTask) ?? .zero(order.currency))

            if selectedOption == nil { selectedOption = defaultOption() }
            if !canPayPartially { amountChoice = .full }
            phase = .loaded
        } catch {
            PRVLog.payments.error("Checkout load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(PaymentsFormatting.friendlyError(error, subject: "This order"))
        }
    }

    /// The row pre-selected when the screen opens: Apple Pay when available,
    /// otherwise the client's default card, otherwise the first method.
    private func defaultOption() -> CheckoutPaymentOption? {
        if isApplePayAvailable { return .applePay }
        if let preferred = savedMethods.first(where: \.isDefault) { return .saved(preferred) }
        return savedMethods.first.map { .saved($0) }
    }

    /// Every way to pay, Apple Pay first.
    var paymentOptions: [CheckoutPaymentOption] {
        (isApplePayAvailable ? [CheckoutPaymentOption.applePay] : []) + savedMethods.map { .saved($0) }
    }

    // MARK: - Money

    /// Currency of this order.
    var currency: Currency { order?.currency ?? .eur }

    /// The salon's prepayment incentives, or the platform default.
    var prepaymentPolicy: PrepaymentPolicy { salon?.prepaymentPolicy ?? PrepaymentPolicy() }

    /// What is still owed on the order, before tips and credits.
    var outstandingBalance: Money { order?.outstandingBalance ?? .zero(currency) }

    /// The portion of the order that carries VAT — everything except tips,
    /// which are outside the scope of the tax.
    var taxableTotal: Money {
        guard let order else { return .zero(currency) }
        let tips = order.lines
            .filter { $0.kind == .tip }
            .reduce(Money.zero(order.currency)) { $0 + $1.total }
        return clampedToZero(order.total - tips)
    }

    /// The VAT contained in the order's prices.
    var vat: VATBreakdown {
        pricing.vatBreakdown(gross: taxableTotal, ratePercent: order?.vatPercent ?? 21)
    }

    /// The tip resolved against the outstanding balance.
    var tipAmount: Money {
        switch tipChoice {
        case .none:
            return .zero(currency)
        case .percent(let percent):
            return Tip.percent(Decimal(percent)).resolved(on: outstandingBalance)
        case .custom:
            return PaymentsFormatting.parseAmount(customTipText, currency: currency) ?? .zero(currency)
        }
    }

    /// Balance plus tip — what settling in full costs today.
    var totalWithTip: Money { outstandingBalance + tipAmount }

    /// The smallest prepayment the salon accepts on this order, when it offers
    /// deposits at all.
    var depositAmount: Money {
        prepayment.minimumDeposit(policy: prepaymentPolicy, orderTotal: outstandingBalance)
            ?? .zero(currency)
    }

    /// Whether the deposit control is worth showing: a future visit, a real
    /// deposit level, and a balance big enough to leave something behind.
    var canPayPartially: Bool {
        guard let order, order.appointmentID != nil else { return false }
        let deposit = depositAmount
        return !deposit.isZero && deposit < outstandingBalance
    }

    /// The deposit-then-balance schedule shown under the partial-payment
    /// control, always reconciling to the outstanding balance.
    var depositSchedule: PaymentSchedule {
        planner.depositSchedule(
            total: outstandingBalance,
            deposit: depositAmount,
            depositDueAt: .now,
            balanceDueAt: .now
        )
    }

    /// What the client owes today before credits are applied.
    var amountBeforeCredits: Money {
        switch amountChoice {
        case .full: totalWithTip
        case .deposit: depositAmount + tipAmount
        }
    }

    /// How much of the redeemed gift card this payment consumes.
    var giftCardCredit: Money {
        guard let card = appliedGiftCard else { return .zero(currency) }
        let balance = Money(card.remainingBalance.amount, currency)
        return lesser(clampedToZero(balance), amountBeforeCredits)
    }

    /// How much store credit this payment consumes.
    var storeCreditApplied: Money {
        guard usesStoreCredit else { return .zero(currency) }
        let remaining = clampedToZero(amountBeforeCredits - giftCardCredit)
        return lesser(storeCreditBalance, remaining)
    }

    /// What the selected payment method is charged.
    var amountDueOnMethod: Money {
        clampedToZero(amountBeforeCredits - giftCardCredit - storeCreditApplied)
    }

    /// What stays outstanding after today's payment.
    var remainingAfterPayment: Money {
        clampedToZero(totalWithTip - amountBeforeCredits)
    }

    /// Cashback the salon grants on what is being paid now.
    var projectedCashback: Money {
        let percent = clampPercent(prepaymentPolicy.cashbackPercent)
        guard percent > 0 else { return .zero(currency) }
        return amountBeforeCredits.percentage(Decimal(percent))
    }

    /// Whether the Pay button can fire.
    var canPay: Bool {
        guard phase == .loaded, !paymentPhase.isProcessing else { return false }
        guard !amountBeforeCredits.isZero else { return false }
        return !amountDueOnMethod.isZero ? selectedOption != nil : true
    }

    /// Label for the primary action, e.g. `"Pay €218.90"`.
    var payButtonTitle: String {
        amountDueOnMethod.isZero && !amountBeforeCredits.isZero
            ? "Complete with credit"
            : "Pay \(amountDueOnMethod.formatted)"
    }

    // MARK: - Gift cards & credit

    /// Redeems a gift-card code and applies its balance to this payment.
    func redeemGiftCard(code rawCode: String, using deps: PRVDependencies) async {
        let code = PaymentsFormatting.normalizedGiftCardCode(rawCode)
        guard !code.isBlank else {
            toast = .warning("Enter the code printed on the card.")
            return
        }
        do {
            let card = try await deps.payments.redeemGiftCard(code: code)
            guard card.remainingBalance.amount > 0 else {
                toast = .warning("This gift card has already been spent.")
                return
            }
            if let expiry = card.expiresAt, expiry < .now {
                toast = .warning("This gift card expired on \(expiry.formatted(date: .abbreviated, time: .omitted)).")
                return
            }
            appliedGiftCard = card
            isRedeemingGiftCard = false
            PRVHaptics.success()
            toast = .success("\(card.remainingBalance.formatted) gift card applied")
        } catch {
            PRVHaptics.warning()
            toast = .error(PaymentsFormatting.friendlyError(error, subject: "That gift card"))
        }
    }

    /// Removes a previously applied gift card.
    func removeGiftCard() {
        appliedGiftCard = nil
        PRVHaptics.tap()
    }

    /// Toggles store credit, refusing when there is nothing to spend.
    func toggleStoreCredit() {
        guard storeCreditBalance.amount > 0 else {
            toast = .info("You have no store credit yet.")
            return
        }
        usesStoreCredit.toggle()
        PRVHaptics.tap()
    }

    // MARK: - Paying

    /// Charges the payment: Apple Pay authorization first when it applies,
    /// then credits, then the remainder on the selected method.
    ///
    /// Every leg posts through `PaymentRepository.pay(orderID:method:amount:)`
    /// so the wallet ledger records each tender separately, exactly as the
    /// receipt shows it.
    func pay(using deps: PRVDependencies) async {
        guard canPay, let order else { return }
        let due = amountDueOnMethod
        let option = selectedOption

        if !due.isZero, option == .applePay {
            paymentPhase = .processing("Waiting for Apple Pay…")
            let outcome = await applePay.authorize(applePayRequest(for: due))
            switch outcome {
            case .authorized:
                break
            case .cancelled:
                paymentPhase = .idle
                return
            case .unavailable(let message):
                PRVHaptics.warning()
                paymentPhase = .idle
                toast = .warning(message)
                return
            }
        }

        paymentPhase = .processing("Securing your payment…")
        var latest = order
        var charged = Money.zero(currency)

        do {
            if !giftCardCredit.isZero {
                latest = try await deps.payments.pay(orderID: orderID, method: .giftCard, amount: giftCardCredit)
                charged = charged + giftCardCredit
            }
            if !storeCreditApplied.isZero {
                latest = try await deps.payments.pay(orderID: orderID, method: .storeCredit, amount: storeCreditApplied)
                charged = charged + storeCreditApplied
            }
            if !due.isZero, let option {
                latest = try await deps.payments.pay(orderID: orderID, method: option.kind, amount: due)
                charged = charged + due
            }

            self.order = latest
            let invoice = await invoice(for: latest, using: deps)
            let receipt = CheckoutReceipt(
                order: latest,
                charged: charged,
                cashback: cashback(on: charged),
                points: latest.pointsEarned,
                invoice: invoice,
                giftCardCode: appliedGiftCard?.code
            )
            PRVHaptics.success()
            paymentPhase = .succeeded(receipt)
        } catch {
            PRVLog.payments.error("Payment failed: \(String(describing: error), privacy: .public)")
            PRVHaptics.error()
            self.order = latest
            paymentPhase = .failed(PaymentsFormatting.paymentError(error))
        }
    }

    /// Clears a failed charge so the client can pick another method.
    func dismissPaymentFailure() {
        guard case .failed = paymentPhase else { return }
        paymentPhase = .idle
    }

    /// The Apple Pay sheet contents for the amount being charged.
    private func applePayRequest(for amount: Money) -> ApplePayRequest {
        var lines: [ApplePayLine] = []
        if let order {
            for line in order.lines where line.kind != .tip {
                lines.append(ApplePayLine(label: line.title, amount: line.total))
            }
            if !order.discount.isZero {
                lines.append(
                    ApplePayLine(
                        label: order.discountReason ?? "Discount",
                        amount: Money(-order.discount.amount, currency)
                    )
                )
            }
        }
        if !tipAmount.isZero { lines.append(ApplePayLine(label: "Tip", amount: tipAmount)) }
        if !giftCardCredit.isZero {
            lines.append(ApplePayLine(label: "Gift card", amount: Money(-giftCardCredit.amount, currency)))
        }
        if !storeCreditApplied.isZero {
            lines.append(ApplePayLine(label: "Store credit", amount: Money(-storeCreditApplied.amount, currency)))
        }
        return ApplePayRequest(
            merchantName: salon?.name ?? "PRV Beauty",
            lines: lines,
            total: amount,
            countryCode: salon?.address.country ?? "BE"
        )
    }

    /// The invoice for a settled order, once the backend has issued one.
    private func invoice(for order: Order, using deps: PRVDependencies) async -> Invoice? {
        guard order.status == .paid else { return nil }
        let invoices = (try? await deps.payments.invoices(userID: order.clientID)) ?? []
        return invoices.first { $0.orderID == order.id }
    }

    /// Cashback earned on an amount under the salon's prepayment policy.
    private func cashback(on amount: Money) -> Money {
        let percent = clampPercent(prepaymentPolicy.cashbackPercent)
        guard percent > 0 else { return .zero(currency) }
        return amount.percentage(Decimal(percent))
    }

    // MARK: - Local money helpers

    /// Clamps an amount to zero; payable money is never negative.
    private func clampedToZero(_ money: Money) -> Money {
        money.amount < 0 ? .zero(money.currency) : money
    }

    /// The smaller of two amounts.
    private func lesser(_ lhs: Money, _ rhs: Money) -> Money {
        lhs.amount <= rhs.amount ? lhs : rhs
    }

    /// Clamps an integer percentage into `0...100`.
    private func clampPercent(_ percent: Int) -> Int {
        Swift.min(100, Swift.max(0, percent))
    }
}
