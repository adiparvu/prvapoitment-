import Foundation
import SwiftUI
import PRVFoundation
import PRVModels

/// Why a card could not be vaulted.
enum CardTokenizationError: Error, Hashable, Sendable {
    /// The build has no Stripe publishable key, so no secure sheet can open.
    case notConfigured
    /// The PCI-scoped card sheet is not present in this build.
    case handoffUnavailable
    /// The client backed out of the secure sheet.
    case cancelled

    /// Client-facing explanation.
    var message: String {
        switch self {
        case .notConfigured:
            "Secure card entry isn't configured for this build. Add a card at the salon, or pay with Apple Pay."
        case .handoffUnavailable:
            "Secure card entry opens in Stripe's own sheet, which isn't available in this build. Apple Pay works today."
        case .cancelled:
            "Card entry was cancelled."
        }
    }
}

/// The boundary at which card data would leave the app.
///
/// PRV Beauty is deliberately out of PCI scope: no view in this module has a
/// text field for a card number, and no type here can hold one. A conforming
/// tokenizer hands control to Stripe's own sheet, which collects the PAN,
/// vaults it, and returns nothing but a token plus the last four digits —
/// which is exactly the shape of ``SavedPaymentMethod``.
///
/// The app target injects a live implementation through
/// `EnvironmentValues.prvCardTokenizer`; this module ships the honest default
/// below.
protocol CardTokenizer: Sendable {
    /// Opens the secure card sheet and returns the vaulted method.
    /// - Parameters:
    ///   - cardholderName: Non-sensitive metadata collected before the handoff.
    ///   - postalCode: Billing postcode, used for address verification.
    ///   - setAsDefault: Whether the vaulted card becomes the default method.
    func vaultCard(
        cardholderName: String,
        postalCode: String,
        setAsDefault: Bool
    ) async throws -> SavedPaymentMethod
}

/// The default tokenizer: it refuses to collect card details itself.
///
/// It checks that the build carries a Stripe publishable key
/// (`PRVStripePublishableKey` in the app's Info.plist) and then hands off to
/// the PCI-scoped sheet. When that sheet is not part of the build — as in an
/// SDK-free package build — it fails loudly rather than pretending to have
/// vaulted anything, because a payment method that does not exist server-side
/// is worse than no payment method at all.
struct StripeCardTokenizer: CardTokenizer {
    /// Info.plist key carrying the Stripe publishable key.
    static let publishableKeyName = "PRVStripePublishableKey"

    /// The configured publishable key, when the build has one.
    static var publishableKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: publishableKeyName) as? String,
              raw.hasPrefix("pk_")
        else { return nil }
        return raw
    }

    /// Whether a secure card sheet could open at all in this build.
    static var isConfigured: Bool { publishableKey != nil }

    func vaultCard(
        cardholderName: String,
        postalCode: String,
        setAsDefault: Bool
    ) async throws -> SavedPaymentMethod {
        guard Self.isConfigured else {
            PRVLog.payments.notice("Card tokenization requested without a Stripe publishable key")
            throw CardTokenizationError.notConfigured
        }
        throw CardTokenizationError.handoffUnavailable
    }
}

extension EnvironmentValues {
    /// The card-vaulting boundary. Defaults to ``StripeCardTokenizer``; the
    /// app target substitutes the SDK-backed implementation at its root.
    @Entry var prvCardTokenizer: any CardTokenizer = StripeCardTokenizer()
}
