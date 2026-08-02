import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

/// Shared, deterministic display formatting for the payments feature.
/// Pure helpers only — no state, no side effects.
enum PaymentsFormatting {
    /// Maps transport errors to warm, actionable copy — never raw codes.
    /// `subject` names what failed, e.g. `"This order"`.
    static func friendlyError(_ error: any Error, subject: String) -> String {
        if let cardError = error as? CardTokenizationError { return cardError.message }
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        switch apiError {
        case .offline, .network:
            return "You appear to be offline. Check your connection and try again."
        case .notFound:
            return "\(subject) is no longer available."
        case .rateLimited:
            return "Too many requests. Take a breath and try again in a moment."
        case .unauthorized, .forbidden:
            return "Please sign in again to continue."
        case .conflict, .server, .decoding:
            return "Our payment servers are momentarily busy. Please try again shortly."
        }
    }

    /// Payment-specific failure copy: a declined charge is not a server error,
    /// and the client needs to know which one they are looking at.
    static func paymentError(_ error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "We couldn't complete this payment. Please try again."
        }
        switch apiError {
        case .offline, .network:
            return "You appear to be offline. Your card has not been charged."
        case .conflict(let message):
            return message.isBlank ? "This payment was declined. Try another method." : message
        case .forbidden, .unauthorized:
            return "This payment was declined. Try another method."
        case .rateLimited:
            return "Too many attempts. Wait a moment before trying again."
        case .notFound, .server, .decoding:
            return "We couldn't reach the payment network. Your card has not been charged."
        }
    }

    /// Formats an order line's quantity prefix, e.g. `"2 ×"`; empty for one.
    static func quantityPrefix(_ quantity: Int) -> String {
        quantity > 1 ? "\(quantity) × " : ""
    }

    /// A masked card descriptor, e.g. `"Visa ···· 4242"`.
    static func methodSubtitle(_ method: SavedPaymentMethod) -> String? {
        guard let lastFour = method.lastFour, !lastFour.isBlank else {
            return method.kind == .applePay ? "Fastest way to pay" : nil
        }
        if let month = method.expiryMonth, let year = method.expiryYear {
            return "···· \(lastFour) · Expires \(String(format: "%02d/%02d", month, year % 100))"
        }
        return "···· \(lastFour)"
    }

    /// Invoice line, e.g. `"Invoice PRV-1001 · 2 March 2026"`.
    static func invoiceSubtitle(_ invoice: Invoice) -> String {
        "\(invoice.number) · \(invoice.issuedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Normalizes a gift-card code the way clients type it: trimmed, upper
    /// case, without the separators they add out of habit.
    static func normalizedGiftCardCode(_ raw: String) -> String {
        raw.trimmed.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Parses a hand-typed money amount, accepting both `,` and `.` as the
    /// decimal separator. Returns `nil` for anything that is not a positive
    /// amount.
    static func parseAmount(_ raw: String, currency: Currency) -> Money? {
        let cleaned = raw.trimmed.replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value > 0
        else { return nil }
        return Money(value.rounded(scale: 2), currency)
    }
}
