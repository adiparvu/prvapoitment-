import Foundation
import PRVFoundation
import PRVModels
#if canImport(PassKit)
import PassKit
#endif

/// What came back from the Apple Pay sheet.
enum ApplePayOutcome: Hashable, Sendable {
    /// The user authorized the payment; the token was handed to the payment
    /// processor server-side.
    case authorized
    /// The user dismissed the sheet without paying.
    case cancelled
    /// Apple Pay cannot run on this device, or the sheet refused to present.
    case unavailable(String)
}

/// One priced row shown in the Apple Pay sheet.
struct ApplePayLine: Hashable, Sendable {
    var label: String
    var amount: Money

    init(label: String, amount: Money) {
        self.label = label
        self.amount = amount
    }
}

/// Everything the Apple Pay sheet needs to describe the charge.
struct ApplePayRequest: Hashable, Sendable {
    /// The salon being paid — shown as the final "grand total" label.
    var merchantName: String
    /// Itemized rows above the total.
    var lines: [ApplePayLine]
    /// What is actually charged.
    var total: Money
    /// ISO country of the acquiring merchant.
    var countryCode: String

    init(merchantName: String, lines: [ApplePayLine] = [], total: Money, countryCode: String = "BE") {
        self.merchantName = merchantName
        self.lines = lines
        self.total = total
        self.countryCode = countryCode
    }
}

/// Drives the Apple Pay sheet and bridges its delegate callbacks into
/// `async/await`.
///
/// The coordinator deliberately never sees a card number: Apple returns an
/// encrypted payment token, which the app forwards to the PRV Edge Function
/// that creates the Stripe payment intent. Authorization here means "the user
/// approved the charge"; the money moves server-side through
/// `PaymentRepository.pay(orderID:method:amount:)`.
///
/// PassKit delivers its callbacks on an unspecified queue, so the continuation
/// and the authorization flag live behind a lock and every delegate method is
/// `nonisolated` — no assumption is made about which actor is running.
final class ApplePayCoordinator: NSObject, @unchecked Sendable {
    /// The merchant identifier provisioned for PRV Beauty.
    static let merchantIdentifier = "merchant.com.prv.beauty"

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApplePayOutcome, Never>?
    private var didAuthorize = false

    /// Whether this device can present the Apple Pay sheet with a usable card.
    static var isAvailable: Bool {
        #if canImport(PassKit)
        return PKPaymentAuthorizationController.canMakePayments()
        #else
        return false
        #endif
    }

    /// Presents the Apple Pay sheet and waits for the user's decision.
    ///
    /// Always returns — a dismissal resolves to ``ApplePayOutcome/cancelled``
    /// rather than leaving the caller suspended.
    @MainActor
    func authorize(_ request: ApplePayRequest) async -> ApplePayOutcome {
        #if canImport(PassKit)
        guard Self.isAvailable else {
            return .unavailable("Apple Pay isn't set up on this device.")
        }
        let paymentRequest = Self.makePaymentRequest(request)
        let controller = PKPaymentAuthorizationController(paymentRequest: paymentRequest)
        controller.delegate = self

        // The completion is explicitly `@Sendable` so it never inherits main-actor
        // isolation: PassKit does not promise which queue calls it back.
        let onPresented: @Sendable (Bool) -> Void = { [self] presented in
            guard !presented else { return }
            resolve(with: .unavailable("Apple Pay couldn't open. Try another payment method."))
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<ApplePayOutcome, Never>) in
            lock.withLock {
                self.continuation = continuation
                self.didAuthorize = false
            }
            controller.present(completion: onPresented)
        }
        #else
        return .unavailable("Apple Pay isn't available on this platform.")
        #endif
    }

    /// Resolves the pending continuation exactly once.
    private func resolve(with outcome: ApplePayOutcome) {
        let pending = lock.withLock { () -> CheckedContinuation<ApplePayOutcome, Never>? in
            let stored = continuation
            continuation = nil
            return stored
        }
        pending?.resume(returning: outcome)
    }

    /// Resolves with whatever the sheet recorded before it closed.
    private func resolveWithRecordedOutcome() {
        let authorized = lock.withLock { didAuthorize }
        resolve(with: authorized ? .authorized : .cancelled)
    }
}

#if canImport(PassKit)

extension ApplePayCoordinator: PKPaymentAuthorizationControllerDelegate {
    /// The user approved the charge. The encrypted token never leaves this
    /// method: the charge itself is created server-side.
    nonisolated func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        lock.withLock { didAuthorize = true }
        PRVLog.payments.info("Apple Pay authorization approved by the user")
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
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

extension ApplePayCoordinator {
    /// Builds the PassKit request from the PRV request.
    fileprivate static func makePaymentRequest(_ request: ApplePayRequest) -> PKPaymentRequest {
        let paymentRequest = PKPaymentRequest()
        paymentRequest.merchantIdentifier = merchantIdentifier
        paymentRequest.countryCode = request.countryCode
        paymentRequest.currencyCode = request.total.currency.rawValue
        paymentRequest.merchantCapabilities = [.threeDSecure]
        paymentRequest.supportedNetworks = [.visa, .masterCard, .amex, .maestro]
        paymentRequest.paymentSummaryItems =
            request.lines.map { summaryItem(label: $0.label, amount: $0.amount) }
            + [summaryItem(label: request.merchantName, amount: request.total)]
        return paymentRequest
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
}

#endif
