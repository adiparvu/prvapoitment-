import Foundation
import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking

// =============================================================================
// MARK: - How payments work in PRV Beauty
// =============================================================================
//
// PRV Beauty takes real money with **no third-party SDK linked into the app**.
// Two Apple system frameworks and one server do all of the work:
//
//   PassKit                → Apple Pay
//   AuthenticationServices → Stripe's own hosted payment page, for cards
//   Supabase Edge Functions → everything that decides what to charge
//
// ## The three rules this module is built on
//
// 1. **The server is the only party that knows the amount.**
//    The client sends *inputs* — which order, how much tip, which deposit
//    level, which gift-card code, whether to spend store credit — and
//    `create-payment-intent` recomputes the figure from `order_totals`, the
//    same view the receipt is rendered from. Whatever the app believed the
//    total was is ignored by the server and is carried here only so the Apple
//    Pay sheet can be itemized and so a drift between the two arithmetics can
//    be logged. `PRVPaymentsKit` produces the *quote*; Stripe captures the
//    *price*.
//
// 2. **The webhook is the only thing that marks an order paid.**
//    Neither the Apple Pay sheet closing nor the hosted page redirecting back
//    means the money moved: the app can be killed mid-flight, and a redirect
//    URL is client-controlled. `stripe-webhook` is the single writer of
//    `orders.status = 'paid'`. After the user finishes authorizing, this
//    module *polls the order* until the webhook lands, with a bounded timeout,
//    and reports "still settling" rather than inventing a success.
//
// 3. **No card data can exist in this process.**
//    Apple Pay returns an encrypted payment token that only the acquirer can
//    open. Cards are entered on Stripe's page inside
//    `ASWebAuthenticationSession`, in a browser context the app cannot read.
//    There is no type in this module that can hold a PAN, and no view with a
//    field for one.
//
// ## Why a protocol
//
// ``PaymentServiceProtocol`` is the seam. The UI knows nothing about PassKit,
// about hosted pages, or about Stripe — it hands over a
// ``PaymentSettlementRequest`` and gets back a ``PaymentSettlement``. A team
// that later wants the native Stripe `PaymentSheet` writes one new conformer,
// injects it at the app root through ``EnvironmentValues/prvPaymentService``,
// and changes **nothing** in `CheckoutView`, `CheckoutModel`, or any of the
// checkout sections. The same seam is what lets previews, demo mode, and tests
// run the whole checkout screen against ``DemoPaymentService`` without a
// network.
//
// ## The pieces
//
// | Type                        | Responsibility                                  |
// |-----------------------------|-------------------------------------------------|
// | ``PaymentServiceProtocol``  | The seam the UI talks to                        |
// | ``StripePaymentService``    | Live: intent → authorize → poll                 |
// | ``DemoPaymentService``      | Previews/demo: settles through the repository   |
// | ``PaymentIntentGateway``    | Typed calls into the payment Edge Functions     |
// | ``ApplePayCoordinator``     | `PKPaymentAuthorizationController`, end to end  |
// | ``HostedCheckoutSession``   | `ASWebAuthenticationSession` + callback URL     |
//
// =============================================================================

// MARK: - Channel

/// How the remainder of a payment reaches Stripe.
///
/// The two live channels are deliberately the only two: Apple Pay, which is a
/// system framework and therefore fully implementable here, and Stripe's own
/// hosted page, which needs no SDK because the card never enters this process.
public enum PaymentChannel: Hashable, Sendable {
    /// `PKPaymentAuthorizationController`; the token is confirmed server-side.
    case applePay
    /// Stripe's hosted payment page, opened in `ASWebAuthenticationSession`.
    /// - Parameter savedMethodID: A vaulted method to preselect, when the
    ///   client picked one from their wallet.
    case hostedCard(savedMethodID: SavedPaymentMethod.ID?)
    /// Nothing reaches a card: gift-card balance and store credit cover the
    /// whole amount, and the server settles the order outright.
    case balancesOnly

    /// The `payment_channel` value sent to `create-payment-intent`.
    public var wireValue: String {
        switch self {
        case .applePay: "apple_pay"
        case .hostedCard: "hosted_card"
        case .balancesOnly: "balances_only"
        }
    }

    /// The tender recorded in the wallet ledger for this channel, or `nil`
    /// when no payment method is charged at all.
    public var methodKind: PaymentMethodKind? {
        switch self {
        case .applePay: .applePay
        case .hostedCard: .card
        case .balancesOnly: nil
        }
    }

    /// The vaulted method the client chose, when they chose one.
    public var savedMethodID: SavedPaymentMethod.ID? {
        guard case .hostedCard(let id) = self else { return nil }
        return id
    }
}

// MARK: - Request

/// One priced row shown above the total in the Apple Pay sheet.
public struct PaymentSummaryLine: Hashable, Sendable {
    /// What the row is called, e.g. `"Balayage"` or `"Gift card"`.
    public var label: String
    /// The row's amount; negative for a reduction.
    public var amount: Money

    /// Creates a summary row.
    public init(label: String, amount: Money) {
        self.label = label
        self.amount = amount
    }
}

/// Everything a payment service needs to settle one order.
///
/// The `quoted…` properties are the client's own arithmetic, produced by
/// `PRVPaymentsKit` and already shown on screen. The live service sends the
/// *inputs* above them — `tip`, `prepaymentPercent`, `giftCardCode`,
/// `usesStoreCredit` — and charges whatever the server prices from those; the
/// quotes are used only to itemize the Apple Pay sheet and to log a drift.
/// ``DemoPaymentService`` has no server to ask, so it settles the quote.
public struct PaymentSettlementRequest: Hashable, Sendable {
    /// The order being settled.
    public var orderID: Order.ID
    /// How the remainder is paid.
    public var channel: PaymentChannel
    /// The salon being paid — the Apple Pay sheet's grand-total label.
    public var merchantName: String
    /// ISO 3166-1 alpha-2 country of the acquiring merchant.
    public var countryCode: String
    /// The order's currency.
    public var currency: Currency
    /// The tip the client added at checkout, in major units.
    public var tip: Money
    /// The deposit level being paid, or `nil` when settling in full. The salon
    /// publishes the levels it accepts; the server rejects any other.
    public var prepaymentPercent: Int?
    /// A redeemed gift-card code to spend against this order.
    public var giftCardCode: String?
    /// Whether the client's store credit is being spent.
    public var usesStoreCredit: Bool
    /// Whether the instrument should be vaulted for future off-session use.
    public var savePaymentMethod: Bool
    /// Itemization for the Apple Pay sheet, in display order.
    public var summaryLines: [PaymentSummaryLine]
    /// What the client was quoted for the payment method itself.
    public var quotedAmountDue: Money
    /// The gift-card balance the client was quoted against this payment.
    public var quotedGiftCardCredit: Money
    /// The store credit the client was quoted against this payment.
    public var quotedStoreCredit: Money

    /// Creates a settlement request.
    public init(
        orderID: Order.ID,
        channel: PaymentChannel,
        merchantName: String,
        countryCode: String,
        currency: Currency,
        tip: Money,
        prepaymentPercent: Int? = nil,
        giftCardCode: String? = nil,
        usesStoreCredit: Bool = false,
        savePaymentMethod: Bool = false,
        summaryLines: [PaymentSummaryLine] = [],
        quotedAmountDue: Money,
        quotedGiftCardCredit: Money,
        quotedStoreCredit: Money
    ) {
        self.orderID = orderID
        self.channel = channel
        self.merchantName = merchantName
        self.countryCode = countryCode
        self.currency = currency
        self.tip = tip
        self.prepaymentPercent = prepaymentPercent
        self.giftCardCode = giftCardCode
        self.usesStoreCredit = usesStoreCredit
        self.savePaymentMethod = savePaymentMethod
        self.summaryLines = summaryLines
        self.quotedAmountDue = quotedAmountDue
        self.quotedGiftCardCredit = quotedGiftCardCredit
        self.quotedStoreCredit = quotedStoreCredit
    }
}

// MARK: - Result

/// What actually happened, once the backend has confirmed it.
public struct PaymentSettlement: Hashable, Sendable {
    /// The order as the backend holds it after settlement.
    public var order: Order
    /// What the payment method was charged.
    public var amountChargedToMethod: Money
    /// The gift-card balance the server consumed.
    public var giftCardApplied: Money
    /// The store credit the server consumed.
    public var storeCreditApplied: Money
    /// The Stripe PaymentIntent behind the charge, when one was created.
    public var paymentIntentID: String?

    /// Creates a settlement.
    public init(
        order: Order,
        amountChargedToMethod: Money,
        giftCardApplied: Money,
        storeCreditApplied: Money,
        paymentIntentID: String? = nil
    ) {
        self.order = order
        self.amountChargedToMethod = amountChargedToMethod
        self.giftCardApplied = giftCardApplied
        self.storeCreditApplied = storeCreditApplied
        self.paymentIntentID = paymentIntentID
    }

    /// Everything collected across every tender — what the receipt shows.
    public var totalCollected: Money {
        amountChargedToMethod + giftCardApplied + storeCreditApplied
    }
}

// MARK: - Progress

/// The step a settlement is currently on, so the processing overlay can name
/// the wait instead of spinning anonymously.
public enum PaymentProgress: Hashable, Sendable {
    /// Asking the server for a PaymentIntent.
    case preparing
    /// The Apple Pay sheet is up, waiting for the double-click.
    case awaitingApplePay
    /// Stripe's hosted page is up, waiting for the client to finish.
    case awaitingHostedPage
    /// The authorization is in, waiting for the webhook to settle the order.
    case settling

    /// Client-facing copy for the processing overlay.
    public var message: String {
        switch self {
        case .preparing: "Securing your payment…"
        case .awaitingApplePay: "Waiting for Apple Pay…"
        case .awaitingHostedPage: "Finishing on Stripe's secure page…"
        case .settling: "Confirming your payment…"
        }
    }
}

// MARK: - Errors

/// Why a payment did not complete.
///
/// Distinct from `APIError` on purpose: "the client closed the sheet" and "the
/// bank said no" are not transport failures, and checkout has to tell them
/// apart to decide between silence, a retry, and an apology.
public enum PaymentServiceError: Error, Hashable, Sendable {
    /// The client dismissed the Apple Pay sheet or the hosted page.
    case cancelled
    /// The build has no payment gateway wired, so nothing can be charged.
    case notConfigured(String)
    /// Apple Pay cannot run here — no supported card, or the sheet refused.
    case applePayUnavailable(String)
    /// The issuer or Stripe refused the charge.
    case declined(String)
    /// Authorization succeeded but the webhook had not settled the order
    /// before the timeout. The money may well have moved; the receipt cannot
    /// be shown yet.
    case awaitingSettlement
    /// The secure sheet could not be presented at all.
    case presentationFailed(String)
    /// The server priced this order at zero — there is nothing to charge.
    case nothingToPay

    /// Client-facing explanation, ready to render.
    public var message: String {
        switch self {
        case .cancelled:
            "Payment cancelled. Nothing has been charged."
        case .notConfigured(let detail):
            detail
        case .applePayUnavailable(let detail):
            detail
        case .declined(let detail):
            detail.isBlank ? "This payment was declined. Try another method." : detail
        case .awaitingSettlement:
            "Your payment is still being confirmed. It will appear in your wallet shortly — don't pay again."
        case .presentationFailed(let detail):
            detail
        case .nothingToPay:
            "There is nothing left to pay on this order."
        }
    }
}

// MARK: - The seam

/// The client side of taking a payment.
///
/// One method, because there is only one thing checkout needs: turn a priced
/// order into money in the salon's account, and hand back the order as the
/// backend now holds it.
///
/// - Important: This protocol is the drop-in point for a different payment
///   stack. A native Stripe `PaymentSheet` integration — or Adyen, or a
///   terminal SDK — conforms to this and is injected at the app root through
///   ``EnvironmentValues/prvPaymentService``. No view, no checkout section,
///   and no line of `CheckoutModel` changes when it does: they know only this
///   protocol, ``PaymentSettlementRequest``, and ``PaymentSettlement``.
///
/// ``settle(_:orders:progress:)`` is main-actor isolated because both live
/// channels present system UI, and because the progress callback drives an
/// `@Observable` screen model.
public protocol PaymentServiceProtocol: Sendable {
    /// Whether this service can offer the Apple Pay row at all.
    ///
    /// Combines the device's own capability with the service's: a stack that
    /// does not implement Apple Pay answers `false` and the row disappears.
    var supportsApplePay: Bool { get }

    /// Settles one order and returns what was collected.
    ///
    /// - Parameters:
    ///   - request: The order, the channel, and the client's choices.
    ///   - orders: The payment repository, used to read the order back once
    ///     the backend has settled it. The repository — not the sheet, not the
    ///     redirect — is the source of truth for "this is paid".
    ///   - progress: Called on the main actor as the flow moves between steps,
    ///     so the processing overlay can say what is happening.
    /// - Throws: ``PaymentServiceError`` for anything the client caused or
    ///   needs to act on; `APIError` for transport failures.
    @MainActor
    func settle(
        _ request: PaymentSettlementRequest,
        orders: any PaymentRepository,
        progress: @MainActor (PaymentProgress) -> Void
    ) async throws -> PaymentSettlement
}

// MARK: - Injection

extension EnvironmentValues {
    /// The payment stack checkout uses.
    ///
    /// Defaults to ``DemoPaymentService``, which settles through whatever
    /// `PaymentRepository` it is handed — correct for previews, tests, and
    /// offline demo mode, and paired with `PRVDependencies.inMemory()`.
    ///
    /// Shipping builds **must** inject ``StripePaymentService`` at the app
    /// root, alongside `PRVDependencies.live(…)`:
    ///
    /// ```swift
    /// RootView()
    ///     .environment(\.prvDependencies, .live(client: client))
    ///     .environment(\.prvPaymentService, StripePaymentService(
    ///         gateway: EdgeFunctionPaymentGateway(functions: client)
    ///     ))
    /// ```
    ///
    /// The default is safe to leave in place by accident: pointed at a live
    /// repository it refuses to report success, because it checks that the
    /// order's `amountPaid` actually moved before it returns.
    @Entry public var prvPaymentService: any PaymentServiceProtocol = DemoPaymentService()
}
