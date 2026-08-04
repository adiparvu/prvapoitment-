import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

/// The live payment stack: an Edge Function prices the order, a system sheet
/// authorizes it, and the webhook settles it.
///
/// One `settle` call is three phases, and each phase is somebody else's job:
///
/// ```text
///   ┌──────────────┐  order_id, tip, deposit %,   ┌───────────────────────┐
///   │ this service │  gift card, store credit     │ create-payment-intent │
///   │              │ ───────────────────────────▶ │  (prices the order)   │
///   │              │ ◀─────────────────────────── │                       │
///   └──────────────┘  amount, client_secret,      └───────────────────────┘
///          │           hosted_checkout_url
///          │
///          │  Apple Pay ──▶ PKPaymentAuthorizationController
///          │                  └─ token ──▶ confirm-payment-intent
///          │  Card      ──▶ ASWebAuthenticationSession
///          │                  └─ Stripe's hosted page ──▶ prvbeauty://payment-return
///          ▼
///   ┌──────────────┐  poll order(id:) until amount_paid moves
///   │  settlement  │ ◀────────────── stripe-webhook writes it
///   └──────────────┘
/// ```
///
/// The service never computes a total, never decides that a payment succeeded,
/// and never sees a card number. What it *does* own is the honesty of the
/// waiting: after an authorization it polls the order until the webhook lands,
/// and if the webhook has not landed inside ``settlementTimeout`` it raises
/// ``PaymentServiceError/awaitingSettlement`` rather than showing a receipt for
/// money that may not have moved.
public struct StripePaymentService: PaymentServiceProtocol {
    private let gateway: any PaymentIntentGateway
    private let settlementTimeout: Duration
    private let settlementPollInterval: Duration

    /// Builds the live service.
    ///
    /// - Parameters:
    ///   - gateway: Typed access to the payment Edge Functions. In a shipping
    ///     build this is `EdgeFunctionPaymentGateway(functions: supabaseClient)`.
    ///   - settlementTimeout: How long to wait for `stripe-webhook` to settle
    ///     the order after a successful authorization. Stripe normally
    ///     delivers within a second or two; the default leaves room for a
    ///     retry without leaving the client staring at a spinner.
    ///   - settlementPollInterval: How often the order is re-read while
    ///     waiting.
    public init(
        gateway: any PaymentIntentGateway,
        settlementTimeout: Duration = .seconds(45),
        settlementPollInterval: Duration = .seconds(1)
    ) {
        self.gateway = gateway
        self.settlementTimeout = settlementTimeout
        self.settlementPollInterval = settlementPollInterval
    }

    /// Apple Pay is offered whenever the device can present the sheet.
    public var supportsApplePay: Bool { ApplePayCoordinator.isAvailable }

    /// Prices, authorizes, and waits for settlement.
    @MainActor
    public func settle(
        _ request: PaymentSettlementRequest,
        orders: any PaymentRepository,
        progress: @MainActor (PaymentProgress) -> Void
    ) async throws -> PaymentSettlement {
        progress(.preparing)

        // The baseline is read first and from the repository, not from the
        // screen: everything below decides "did this payment land" by asking
        // whether `amount_paid` moved past this figure.
        let baseline = try await orders.order(id: request.orderID)
        let returnURL = try hostedReturnURL(for: request.channel)

        let envelope = try await gateway.createPaymentIntent(
            PaymentIntentRequest(
                orderID: request.orderID.rawValue,
                prepaymentPercent: request.prepaymentPercent,
                savePaymentMethod: request.savePaymentMethod,
                tipAmount: request.tip.amount.rounded(scale: 2),
                giftCardCode: request.giftCardCode,
                applyStoreCredit: request.usesStoreCredit,
                paymentChannel: request.channel.wireValue,
                returnURL: returnURL
            )
        )

        let priced = envelope.amount
        Self.logPricingDrift(quoted: request.quotedAmountDue, priced: priced)

        if envelope.needsCharge {
            guard !priced.isZero else { throw PaymentServiceError.nothingToPay }
            try await authorize(request, envelope: envelope, priced: priced, progress: progress)
        }

        progress(.settling)
        let settled = try await waitForSettlement(
            orderID: request.orderID,
            paidBefore: baseline.amountPaid,
            orders: orders
        )

        return PaymentSettlement(
            order: settled,
            amountChargedToMethod: envelope.needsCharge ? priced : .zero(request.currency),
            giftCardApplied: envelope.giftCardApplied ?? .zero(request.currency),
            storeCreditApplied: envelope.storeCreditApplied ?? .zero(request.currency),
            paymentIntentID: envelope.paymentIntentID
        )
    }

    // MARK: - Authorization

    /// Runs the channel's authorization step, throwing on anything short of a
    /// clean approval.
    @MainActor
    private func authorize(
        _ request: PaymentSettlementRequest,
        envelope: PaymentIntentEnvelope,
        priced: Money,
        progress: @MainActor (PaymentProgress) -> Void
    ) async throws {
        switch request.channel {
        case .applePay:
            progress(.awaitingApplePay)
            try await authorizeWithApplePay(request, envelope: envelope, priced: priced)

        case .hostedCard:
            progress(.awaitingHostedPage)
            try await authorizeOnHostedPage(envelope: envelope)

        case .balancesOnly:
            // The server priced a charge for a payment the client believed
            // their balances covered — a gift card spent on another device, a
            // credit already consumed. Sending them back to pick a method is
            // the only honest answer.
            PRVLog.payments.notice("Balances no longer cover this order; a payment method is required")
            throw PaymentServiceError.declined(
                "Your balances no longer cover this order. Choose a payment method and try again."
            )
        }
    }

    /// Presents the Apple Pay sheet and confirms the intent from inside it.
    @MainActor
    private func authorizeWithApplePay(
        _ request: PaymentSettlementRequest,
        envelope: PaymentIntentEnvelope,
        priced: Money
    ) async throws {
        // Captured explicitly so the confirmation closure stays `@Sendable`:
        // it must not reach back into `self` or into the screen model.
        let gateway = self.gateway
        let intentID = envelope.paymentIntentID
        let orderID = request.orderID.rawValue

        let sheet = ApplePayRequest(
            merchantName: request.merchantName,
            lines: request.summaryLines,
            // The server's figure, not the app's: the sheet the client approves
            // shows exactly what Stripe will capture.
            total: priced,
            countryCode: request.countryCode
        )

        // Held in a local for the length of the sheet: PassKit's `delegate` is a
        // weak reference, so nothing but this binding keeps the coordinator —
        // and therefore the controller it owns — alive while the user decides.
        let coordinator = ApplePayCoordinator()
        let outcome = await coordinator.authorize(sheet) { token in
            do {
                let confirmation = try await gateway.confirmApplePayPayment(
                    ApplePayConfirmationRequest(
                        paymentIntentID: intentID,
                        orderID: orderID,
                        applePayToken: token.paymentData,
                        paymentNetwork: token.paymentNetwork,
                        transactionIdentifier: token.transactionIdentifier,
                        billingPostalCode: token.billingPostalCode,
                        billingCountry: token.billingCountry
                    )
                )
                guard confirmation.isApproved else {
                    return .declined(
                        confirmation.message ?? "This payment was declined. Try another method."
                    )
                }
                return .approved
            } catch {
                return .declined(PaymentsFormatting.paymentError(error))
            }
        }

        switch outcome {
        case .authorized:
            return
        case .cancelled:
            throw PaymentServiceError.cancelled
        case .declined(let message):
            throw PaymentServiceError.declined(message)
        case .unavailable(let message):
            throw PaymentServiceError.applePayUnavailable(message)
        }
    }

    /// Opens Stripe's hosted page and waits for the callback.
    ///
    /// The redirect is only ever used to stop waiting. Whether the payment
    /// succeeded is decided afterwards, by reading the order back.
    @MainActor
    private func authorizeOnHostedPage(envelope: PaymentIntentEnvelope) async throws {
        guard let hostedURL = envelope.hostedCheckoutURL else {
            PRVLog.payments.error("create-payment-intent returned no hosted checkout URL for a card payment")
            throw PaymentServiceError.notConfigured(
                "Card payments aren't available for this order yet. Pay with Apple Pay, or settle at the salon."
            )
        }

        let hostedPage = HostedCheckoutSession()
        switch await hostedPage.present(hostedURL) {
        case .cancelled:
            throw PaymentServiceError.cancelled
        case .failed(let message):
            throw PaymentServiceError.presentationFailed(message)
        case .returned(let callback):
            guard Self.returnStatus(in: callback) != "cancelled" else {
                throw PaymentServiceError.cancelled
            }
        }
    }

    // MARK: - Settlement

    /// Re-reads the order until the webhook has moved `amount_paid`.
    ///
    /// Transport failures are tolerated and retried — the payment is already in
    /// flight, and a dropped read is not a decline. Only two things end the
    /// wait early: the order settling, and the order being marked failed.
    private func waitForSettlement(
        orderID: Order.ID,
        paidBefore: Money,
        orders: any PaymentRepository
    ) async throws -> Order {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: settlementTimeout)

        while true {
            do {
                let order = try await orders.order(id: orderID)
                if order.status == .failed {
                    throw PaymentServiceError.declined(
                        "Your bank declined this payment. Try another method to keep your slot."
                    )
                }
                if order.amountPaid > paidBefore || order.status == .paid {
                    return order
                }
            } catch let error as PaymentServiceError {
                throw error
            } catch {
                PRVLog.payments.notice("Could not read the order while waiting for settlement; retrying")
            }

            guard clock.now < deadline else { break }
            try await Task.sleep(for: settlementPollInterval)
        }

        PRVLog.payments.error(
            "Payment authorized but order \(orderID.description, privacy: .public) had not settled before the timeout"
        )
        throw PaymentServiceError.awaitingSettlement
    }

    // MARK: - Helpers

    /// The callback URL a hosted page must redirect to, for channels that use
    /// one. `nil` for channels that do not.
    private func hostedReturnURL(for channel: PaymentChannel) throws -> URL? {
        guard case .hostedCard = channel else { return nil }
        guard let url = PaymentReturnURL.url(for: .payment) else {
            throw PaymentServiceError.notConfigured(
                "Card payments aren't configured in this build. Apple Pay works today."
            )
        }
        return url
    }

    /// The `status` hint a hosted page appends to its callback, when it does.
    private static func returnStatus(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "status" }?
            .value
    }

    /// Records a disagreement between what the app quoted and what the server
    /// priced.
    ///
    /// It is never an error — the server is authoritative and the client always
    /// sees the real figure in the Apple Pay sheet or on Stripe's page — but a
    /// persistent drift means `PRVPaymentsKit` and the Edge Function have
    /// stopped agreeing, which is worth knowing before a client notices.
    private static func logPricingDrift(quoted: Money, priced: Money) {
        guard quoted.currency == priced.currency, quoted.amount != priced.amount else { return }
        PRVLog.payments.notice(
            "Pricing drift: the app quoted \(quoted.formatted, privacy: .public), the server priced \(priced.formatted, privacy: .public)"
        )
    }
}
