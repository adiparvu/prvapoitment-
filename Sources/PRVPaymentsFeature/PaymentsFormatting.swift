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
        if let paymentError = error as? PaymentServiceError { return paymentError.message }
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
        case .conflict(let body):
            return serverMessage(in: body)
                ?? "Our payment servers are momentarily busy. Please try again shortly."
        case .server(_, let body):
            return serverMessage(in: body ?? "")
                ?? "Our payment servers are momentarily busy. Please try again shortly."
        case .decoding:
            return "Our payment servers are momentarily busy. Please try again shortly."
        }
    }

    /// Payment-specific failure copy: a declined charge is not a server error,
    /// and the client needs to know which one they are looking at.
    ///
    /// Edge Functions answer with a `{ "error": { "code", "message" } }`
    /// envelope written for the client — "This salon offers prepayment at 30%,
    /// not 5%", "This order has already been paid in full" — so that message is
    /// preferred over anything this function could invent. Only when the body
    /// carries no envelope does the generic copy apply.
    static func paymentError(_ error: any Error) -> String {
        if let paymentError = error as? PaymentServiceError { return paymentError.message }
        if let cardError = error as? CardTokenizationError { return cardError.message }
        guard let apiError = error as? APIError else {
            return "We couldn't complete this payment. Please try again."
        }
        switch apiError {
        case .offline, .network:
            return "You appear to be offline. Your card has not been charged."
        case .conflict(let body):
            return serverMessage(in: body)
                ?? "This payment was declined. Try another method."
        case .forbidden, .unauthorized:
            return "This payment was declined. Try another method."
        case .rateLimited:
            return "Too many attempts. Wait a moment before trying again."
        case .server(_, let body):
            return serverMessage(in: body ?? "")
                ?? "We couldn't reach the payment network. Your card has not been charged."
        case .notFound, .decoding:
            return "We couldn't reach the payment network. Your card has not been charged."
        }
    }

    /// The best client-facing sentence available in a server failure body.
    ///
    /// Edge Functions answer with `{ "error": { "code", "message" } }` where the
    /// message is already written for the client — "This salon offers prepayment
    /// at 30%, not 5%" — and that is always better copy than anything invented
    /// here. The two transports deliver it differently: `SupabaseClient` has
    /// already reduced the envelope to its `message`, while `URLSessionAPIClient`
    /// hands back the raw body. This accepts either, and refuses anything that
    /// still looks like a payload rather than putting JSON in front of a client.
    static func serverMessage(in body: String) -> String? {
        let trimmed = body.trimmed
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let envelope = try? JSONCoding.decoder.decode(EdgeFunctionErrorEnvelope.self, from: data),
           !envelope.error.message.isBlank {
            return envelope.error.message
        }

        let looksStructured = trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("<")
        guard !looksStructured, trimmed.count <= 300 else { return nil }
        return trimmed
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
