import Foundation
import PRVFoundation
import PRVModels
#if canImport(PassKit)
import PassKit
#endif
#if canImport(Contacts)
import Contacts
#endif

// MARK: - Values crossing the sheet boundary

/// The encrypted payment credential Apple hands back after an authorization.
///
/// Every field here is inert: `paymentData` is a blob encrypted to the
/// acquirer's certificate, and nothing in this app — or in the Edge Function
/// that forwards it — can open it. This is what makes Apple Pay implementable
/// end to end without an SDK and without entering PCI scope.
public struct ApplePayToken: Hashable, Sendable {
    /// Base64 of `PKPaymentToken.paymentData`.
    public var paymentData: String
    /// Apple's identifier for this authorization, used to deduplicate
    /// server-side.
    public var transactionIdentifier: String
    /// The card network Apple reported, e.g. `"Visa"`.
    public var paymentNetwork: String?
    /// Billing postcode from the sheet, for address verification.
    public var billingPostalCode: String?
    /// ISO country of the billing address.
    public var billingCountry: String?

    /// Creates a token payload.
    public init(
        paymentData: String,
        transactionIdentifier: String,
        paymentNetwork: String? = nil,
        billingPostalCode: String? = nil,
        billingCountry: String? = nil
    ) {
        self.paymentData = paymentData
        self.transactionIdentifier = transactionIdentifier
        self.paymentNetwork = paymentNetwork
        self.billingPostalCode = billingPostalCode
        self.billingCountry = billingCountry
    }
}

/// What the backend said about an authorization, while the sheet is still open.
public enum ApplePayConfirmationDecision: Hashable, Sendable {
    /// Stripe accepted the charge; the sheet closes with a tick.
    case approved
    /// Stripe refused it; the sheet shows this message and stays actionable.
    case declined(String)
}

/// What came back from the Apple Pay sheet.
public enum ApplePayOutcome: Hashable, Sendable {
    /// The user authorized and the backend confirmed the intent.
    case authorized
    /// The user dismissed the sheet without paying.
    case cancelled
    /// The user authorized but the charge was refused.
    case declined(String)
    /// Apple Pay cannot run on this device, or the sheet refused to present.
    case unavailable(String)
}

/// Everything the Apple Pay sheet needs to describe the charge.
public struct ApplePayRequest: Hashable, Sendable {
    /// The salon being paid — shown as the final "grand total" label.
    public var merchantName: String
    /// Itemized rows above the total, in display order.
    public var lines: [PaymentSummaryLine]
    /// What is actually charged. This is the server's figure, never the app's.
    public var total: Money
    /// ISO 3166-1 alpha-2 country of the acquiring merchant.
    public var countryCode: String

    /// Creates a sheet description.
    public init(
        merchantName: String,
        lines: [PaymentSummaryLine] = [],
        total: Money,
        countryCode: String = "BE"
    ) {
        self.merchantName = merchantName
        self.lines = lines
        self.total = total
        self.countryCode = countryCode
    }
}

// MARK: - Coordinator

/// Drives the Apple Pay sheet and bridges its delegate callbacks into
/// `async/await`.
///
/// The full flow, and why each half is where it is:
///
/// 1. `authorize(_:confirm:)` builds a `PKPaymentRequest` from the order — one
///    summary item per line, plus the tip and any balances applied, then the
///    grand total labelled with the salon's name — and presents
///    `PKPaymentAuthorizationController`.
/// 2. The user double-clicks. PassKit calls `didAuthorizePayment` with a
///    `PKPayment`. The **sheet is still open and waiting**: this is the one
///    window in which a decline can be shown inside Apple's own UI, so the
///    token is forwarded to the backend right here and the sheet is only
///    closed once the backend has answered.
/// 3. The backend confirms the PaymentIntent with the token and reports
///    approved or declined. That answer becomes the `PKPaymentAuthorizationResult`.
/// 4. `didFinish` resolves the `await`.
///
/// The token never becomes a charge on the device — the money moves when
/// `stripe-webhook` sees `payment_intent.succeeded`. "Authorized" here means
/// the user approved and Stripe accepted; ``StripePaymentService`` then waits
/// for the order itself to settle.
///
/// PassKit delivers its callbacks on an unspecified queue, so every piece of
/// mutable state lives behind a lock and every delegate method is
/// `nonisolated` — no assumption is made about which actor is running.
final class ApplePayCoordinator: NSObject, @unchecked Sendable {
    /// The merchant identifier provisioned for PRV Beauty.
    ///
    /// Must match the Merchant ID in the app's Apple Pay entitlement and the
    /// certificate Stripe holds for it.
    static let merchantIdentifier = "merchant.com.prv.beauty"

    #if canImport(PassKit)
    /// The card networks PRV's acquirer settles.
    ///
    /// Bancontact and Maestro matter in the Benelux launch markets; the list is
    /// explicit rather than "everything Apple offers" so a network the acquirer
    /// cannot settle never reaches the sheet.
    static let supportedNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .amex, .maestro]
    #endif

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApplePayOutcome, Never>?
    private var recordedOutcome: ApplePayOutcome?
    private var confirmation: (@Sendable (ApplePayToken) async -> ApplePayConfirmationDecision)?
    #if canImport(PassKit)
    private var controller: PKPaymentAuthorizationController?
    #endif

    /// Whether this device can present the Apple Pay sheet.
    static var isAvailable: Bool {
        #if canImport(PassKit)
        return PKPaymentAuthorizationController.canMakePayments()
        #else
        return false
        #endif
    }

    /// Whether a card this acquirer settles is already provisioned in Wallet.
    ///
    /// Distinct from ``isAvailable``: a device can support Apple Pay with no
    /// usable card, which is a set-up prompt rather than a hidden row.
    static var hasUsableCard: Bool {
        #if canImport(PassKit)
        return PKPaymentAuthorizationController.canMakePayments(usingNetworks: supportedNetworks)
        #else
        return false
        #endif
    }

    /// Presents the Apple Pay sheet and waits for the user's decision.
    ///
    /// Always returns — a dismissal resolves to ``ApplePayOutcome/cancelled``
    /// rather than leaving the caller suspended.
    ///
    /// - Parameters:
    ///   - request: What the sheet shows and what is charged.
    ///   - confirm: Called with the encrypted token while the sheet is still
    ///     open. Forward it to the backend and answer approved or declined;
    ///     the answer is what Apple's own UI shows as it closes.
    @MainActor
    func authorize(
        _ request: ApplePayRequest,
        confirm: @escaping @Sendable (ApplePayToken) async -> ApplePayConfirmationDecision
    ) async -> ApplePayOutcome {
        #if canImport(PassKit)
        guard Self.isAvailable else {
            return .unavailable("Apple Pay isn't set up on this device.")
        }
        guard Self.hasUsableCard else {
            return .unavailable("Add a card to Wallet to pay with Apple Pay, or choose another method.")
        }

        let controller = PKPaymentAuthorizationController(
            paymentRequest: Self.makePaymentRequest(request)
        )
        controller.delegate = self

        lock.withLock {
            self.confirmation = confirm
            self.recordedOutcome = nil
            self.controller = controller
        }

        // The completion is explicitly `@Sendable` so it never inherits
        // main-actor isolation: PassKit does not promise which queue calls it.
        let onPresented: @Sendable (Bool) -> Void = { [self] presented in
            guard !presented else { return }
            PRVLog.payments.error("Apple Pay sheet refused to present")
            resolve(with: .unavailable("Apple Pay couldn't open. Try another payment method."))
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<ApplePayOutcome, Never>) in
            lock.withLock { self.continuation = continuation }
            controller.present(completion: onPresented)
        }
        #else
        return .unavailable("Apple Pay isn't available on this platform.")
        #endif
    }

    // MARK: Continuation plumbing

    /// Records what the sheet decided, for ``resolveWithRecordedOutcome()`` to
    /// pick up once PassKit finishes dismissing.
    fileprivate func record(_ outcome: ApplePayOutcome) {
        lock.withLock { recordedOutcome = outcome }
    }

    /// The confirmation handler installed for the current sheet, if any.
    fileprivate var currentConfirmation: (@Sendable (ApplePayToken) async -> ApplePayConfirmationDecision)? {
        lock.withLock { confirmation }
    }

    /// Resolves the pending continuation exactly once and drops the sheet's
    /// state, so a second callback cannot resume a consumed continuation.
    fileprivate func resolve(with outcome: ApplePayOutcome) {
        let pending = lock.withLock { () -> CheckedContinuation<ApplePayOutcome, Never>? in
            let stored = continuation
            continuation = nil
            confirmation = nil
            recordedOutcome = nil
            #if canImport(PassKit)
            controller = nil
            #endif
            return stored
        }
        pending?.resume(returning: outcome)
    }

    /// Resolves with whatever the sheet recorded before it closed. Nothing
    /// recorded means the user backed out.
    fileprivate func resolveWithRecordedOutcome() {
        let outcome = lock.withLock { recordedOutcome } ?? .cancelled
        resolve(with: outcome)
    }
}

#if canImport(PassKit)

// MARK: - PassKit delegate

extension ApplePayCoordinator: PKPaymentAuthorizationControllerDelegate {
    /// The user approved the charge.
    ///
    /// The encrypted token is forwarded to the backend *before* the sheet
    /// closes, so a decline is shown in Apple's own UI rather than as a banner
    /// on a screen the user has already been returned to.
    nonisolated func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        // PassKit's handler is neither `Sendable` nor re-entrant; the box makes
        // it safe to carry into the task below and impossible to call twice.
        let responder = OneShotHandler(completion)
        let token = Self.makeToken(from: payment)

        guard let confirm = currentConfirmation else {
            PRVLog.payments.error("Apple Pay authorized with no confirmation handler installed")
            record(.declined("This payment couldn't be prepared. Nothing has been charged."))
            responder.run(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            return
        }

        PRVLog.payments.info("Apple Pay authorization approved by the user; confirming server-side")

        Task { [weak self] in
            let decision = await confirm(token)
            switch decision {
            case .approved:
                self?.record(.authorized)
                responder.run(PKPaymentAuthorizationResult(status: .success, errors: nil))
            case .declined(let message):
                PRVLog.payments.error("Apple Pay confirmation declined by the payment server")
                self?.record(.declined(message))
                responder.run(
                    PKPaymentAuthorizationResult(
                        status: .failure,
                        errors: [Self.authorizationError(message)]
                    )
                )
            }
        }
    }

    /// The sheet closed — either after an authorization or because the user
    /// backed out.
    nonisolated func paymentAuthorizationControllerDidFinish(
        _ controller: PKPaymentAuthorizationController
    ) {
        controller.dismiss()
        resolveWithRecordedOutcome()
    }
}

// MARK: - PassKit request building

extension ApplePayCoordinator {
    /// Builds the PassKit request from the PRV request.
    fileprivate static func makePaymentRequest(_ request: ApplePayRequest) -> PKPaymentRequest {
        let paymentRequest = PKPaymentRequest()
        paymentRequest.merchantIdentifier = merchantIdentifier
        paymentRequest.countryCode = request.countryCode
        paymentRequest.currencyCode = request.total.currency.rawValue
        paymentRequest.merchantCapabilities = [.threeDSecure, .credit, .debit]
        paymentRequest.supportedNetworks = supportedNetworks
        // The postcode is the only contact field PRV asks for, and only because
        // the acquirer runs address verification on it.
        paymentRequest.requiredBillingContactFields = [.postalAddress]
        paymentRequest.paymentSummaryItems = summaryItems(for: request)
        return paymentRequest
    }

    /// The itemization: every line, then the grand total labelled with the
    /// salon's name — which is what Apple shows as "Pay <merchant>".
    fileprivate static func summaryItems(for request: ApplePayRequest) -> [PKPaymentSummaryItem] {
        request.lines.map { summaryItem(label: $0.label, amount: $0.amount) }
            + [summaryItem(label: request.merchantName, amount: request.total)]
    }

    /// Converts exact `Decimal` money into the `NSDecimalNumber` PassKit wants
    /// — never via `Double`.
    fileprivate static func summaryItem(label: String, amount: Money) -> PKPaymentSummaryItem {
        PKPaymentSummaryItem(
            label: label,
            amount: NSDecimalNumber(decimal: amount.amount.rounded(scale: 2)),
            type: .final
        )
    }

    /// Extracts the inert parts of a `PKPayment`, so nothing that is not
    /// `Sendable` crosses out of the delegate callback.
    fileprivate static func makeToken(from payment: PKPayment) -> ApplePayToken {
        let billing = billingAddress(of: payment)
        return ApplePayToken(
            paymentData: payment.token.paymentData.base64EncodedString(),
            transactionIdentifier: payment.token.transactionIdentifier,
            paymentNetwork: payment.token.paymentMethod.network?.rawValue,
            billingPostalCode: billing.postalCode,
            billingCountry: billing.country
        )
    }

    /// The postcode and country the sheet collected, when Contacts is part of
    /// the platform. Only these two fields are ever read from the contact.
    fileprivate static func billingAddress(
        of payment: PKPayment
    ) -> (postalCode: String?, country: String?) {
        #if canImport(Contacts)
        let address = payment.billingContact?.postalAddress
        return (address?.postalCode, address?.isoCountryCode)
        #else
        return (nil, nil)
        #endif
    }

    /// The error the sheet renders when the backend declines.
    ///
    /// A PRV-owned domain rather than a `PKPaymentError` field error: nothing
    /// the user typed is wrong, the issuer simply said no.
    fileprivate static func authorizationError(_ message: String) -> any Error {
        NSError(
            domain: "com.prv.beauty.payments",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

#endif
