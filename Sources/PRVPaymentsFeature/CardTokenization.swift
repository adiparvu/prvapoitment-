import Foundation
import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking

/// Why a card could not be vaulted.
public enum CardTokenizationError: Error, Hashable, Sendable {
    /// No card-vaulting gateway is wired into this build.
    case notConfigured
    /// The client backed out of the secure sheet.
    case cancelled
    /// The secure sheet could not be presented, or closed with an error.
    case presentationFailed(String)
    /// Stripe accepted the card but the vaulted method could not be read back.
    case vaultingFailed(String)

    /// Client-facing explanation.
    public var message: String {
        switch self {
        case .notConfigured:
            "Adding a card isn't set up in this build. Pay with Apple Pay, or add a card at the salon."
        case .cancelled:
            "Card entry was cancelled."
        case .presentationFailed(let detail):
            detail
        case .vaultingFailed(let detail):
            detail
        }
    }
}

/// The boundary at which card data would leave the app.
///
/// PRV Beauty is deliberately out of PCI scope: no view in this module has a
/// text field for a card number, and no type here can hold one. A conforming
/// tokenizer hands control to Stripe's own page, which collects the PAN,
/// vaults it, and returns nothing but a token plus the last four digits —
/// which is exactly the shape of ``SavedPaymentMethod``.
///
/// Main-actor isolated because vaulting presents system UI.
public protocol CardTokenizer: Sendable {
    /// Opens the secure card page and returns the vaulted method.
    /// - Parameters:
    ///   - cardholderName: Non-sensitive metadata collected before the handoff.
    ///   - postalCode: Billing postcode, used for address verification.
    ///   - setAsDefault: Whether the vaulted card becomes the default method.
    @MainActor
    func vaultCard(
        cardholderName: String,
        postalCode: String,
        setAsDefault: Bool
    ) async throws -> SavedPaymentMethod
}

/// Vaults a card on Stripe's own hosted setup page — no SDK, no PAN in this
/// process.
///
/// The same shape as a hosted checkout, one step earlier in the client's life:
///
/// 1. `create-setup-intent` opens a Stripe SetupIntent for the signed-in
///    customer and returns the hosted page that collects the card.
/// 2. ``HostedCheckoutSession`` presents that page in
///    `ASWebAuthenticationSession`, so the card is typed in a browser context
///    this app cannot read, and Stripe redirects to `prvbeauty://card-return`
///    when it is done.
/// 3. `vaulted-payment-method` reads the resulting `saved_payment_methods` row
///    back — brand, last four, expiry, default flag. The server is what decides
///    a card was really vaulted; the redirect only says the browser closed.
public struct HostedCardTokenizer: CardTokenizer {
    private let gateway: any CardVaultGateway

    /// Builds the tokenizer over the card-vaulting Edge Functions.
    public init(gateway: any CardVaultGateway) {
        self.gateway = gateway
    }

    /// Runs the hosted setup flow and returns the vaulted method.
    @MainActor
    public func vaultCard(
        cardholderName: String,
        postalCode: String,
        setAsDefault: Bool
    ) async throws -> SavedPaymentMethod {
        guard let returnURL = PaymentReturnURL.url(for: .card) else {
            throw CardTokenizationError.notConfigured
        }

        let setup = try await gateway.createCardSetup(
            CardSetupRequest(
                cardholderName: cardholderName,
                postalCode: postalCode,
                setAsDefault: setAsDefault,
                returnURL: returnURL
            )
        )

        let hostedPage = HostedCheckoutSession()
        switch await hostedPage.present(setup.hostedSetupURL) {
        case .cancelled:
            throw CardTokenizationError.cancelled
        case .failed(let message):
            throw CardTokenizationError.presentationFailed(message)
        case .returned:
            break
        }

        do {
            return try await gateway.vaultedMethod(setupIntentID: setup.setupIntentID)
        } catch APIError.notFound {
            // The browser closed without Stripe confirming the setup — an
            // abandoned page, a failed 3-D Secure step. Nothing was vaulted.
            throw CardTokenizationError.vaultingFailed(
                "That card wasn't saved. Try again, or use Apple Pay."
            )
        } catch {
            PRVLog.payments.error("Could not read back the vaulted card: \(String(describing: error), privacy: .public)")
            throw CardTokenizationError.vaultingFailed(
                PaymentsFormatting.friendlyError(error, subject: "That card")
            )
        }
    }
}

/// The tokenizer a build gets when no card-vaulting gateway has been injected.
///
/// It fails loudly rather than pretending to have vaulted anything: a payment
/// method that does not exist server-side is worse than no payment method at
/// all, because the client only discovers it at the till.
public struct UnconfiguredCardTokenizer: CardTokenizer {
    /// Creates the refusing tokenizer.
    public init() {}

    /// Always throws ``CardTokenizationError/notConfigured``.
    @MainActor
    public func vaultCard(
        cardholderName: String,
        postalCode: String,
        setAsDefault: Bool
    ) async throws -> SavedPaymentMethod {
        PRVLog.payments.notice("Card vaulting requested with no gateway injected")
        throw CardTokenizationError.notConfigured
    }
}

extension EnvironmentValues {
    /// The card-vaulting boundary.
    ///
    /// Defaults to ``UnconfiguredCardTokenizer``; the app root substitutes
    /// ``HostedCardTokenizer`` alongside the live dependencies:
    ///
    /// ```swift
    /// RootView()
    ///     .environment(\.prvCardTokenizer, HostedCardTokenizer(
    ///         gateway: EdgeFunctionPaymentGateway(functions: client)
    ///     ))
    /// ```
    @Entry public var prvCardTokenizer: any CardTokenizer = UnconfiguredCardTokenizer()
}
