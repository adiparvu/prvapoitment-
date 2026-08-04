import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

/// The payment stack for previews, tests, and offline demo mode.
///
/// It settles a payment the only way a backend-less build can: by posting each
/// tender straight to `PaymentRepository.pay(orderID:method:amount:)` — gift
/// card first, then store credit, then the remainder on the chosen method —
/// which is exactly the order and exactly the semantics `InMemoryBackend`
/// implements. A checkout run against it therefore produces the same receipt,
/// the same wallet ledger entries, and the same invoice as the live flow,
/// without a network call or a payment sheet.
///
/// Because it has no server to price the order, this is the one implementation
/// that charges the client's own quote. That is safe here and only here: an
/// in-memory backend has no money in it.
///
/// It presents **no payment sheet**. Putting a real Apple Pay sheet in front of
/// a demo would authorize a genuine payment credential against a charge that
/// does not exist, and would show a real client "Pay Maison Lumière €218.90"
/// for money nobody is taking. Every other checkout state — the processing
/// overlay, the success seal, the receipt, the wallet ledger — behaves exactly
/// as it does live.
///
/// - Important: This service is wired as the default for
///   ``EnvironmentValues/prvPaymentService`` so previews work with zero setup.
///   Pointed at a *live* repository it deliberately refuses to report success:
///   `SupabasePaymentRepository.pay` creates a PaymentIntent and returns the
///   still-unpaid order, so the `amountPaid` check below fails and checkout
///   shows a configuration error instead of a receipt for money nobody took.
public struct DemoPaymentService: PaymentServiceProtocol {
    /// Creates the demo service.
    public init() {}

    /// Apple Pay is offered whenever the device can present the sheet, so the
    /// row is exercised in previews exactly as it is in the app.
    public var supportsApplePay: Bool { ApplePayCoordinator.isAvailable }

    /// Settles the quote through the repository ledger.
    @MainActor
    public func settle(
        _ request: PaymentSettlementRequest,
        orders: any PaymentRepository,
        progress: @MainActor (PaymentProgress) -> Void
    ) async throws -> PaymentSettlement {
        progress(.preparing)

        let before = try await orders.order(id: request.orderID)
        var latest = before
        var giftCardApplied = Money.zero(request.currency)
        var storeCreditApplied = Money.zero(request.currency)
        var chargedToMethod = Money.zero(request.currency)

        if !request.quotedGiftCardCredit.isZero {
            latest = try await orders.pay(
                orderID: request.orderID,
                method: .giftCard,
                amount: request.quotedGiftCardCredit
            )
            giftCardApplied = request.quotedGiftCardCredit
        }

        if !request.quotedStoreCredit.isZero {
            latest = try await orders.pay(
                orderID: request.orderID,
                method: .storeCredit,
                amount: request.quotedStoreCredit
            )
            storeCreditApplied = request.quotedStoreCredit
        }

        if let kind = request.channel.methodKind, !request.quotedAmountDue.isZero {
            progress(.settling)
            latest = try await orders.pay(
                orderID: request.orderID,
                method: kind,
                amount: request.quotedAmountDue
            )
            chargedToMethod = request.quotedAmountDue
        }

        guard latest.amountPaid > before.amountPaid else {
            PRVLog.payments.error("DemoPaymentService settled nothing — no live payment service is wired up")
            throw PaymentServiceError.notConfigured(
                "Payments aren't configured in this build, so nothing has been charged."
            )
        }

        return PaymentSettlement(
            order: latest,
            amountChargedToMethod: chargedToMethod,
            giftCardApplied: giftCardApplied,
            storeCreditApplied: storeCreditApplied
        )
    }
}
