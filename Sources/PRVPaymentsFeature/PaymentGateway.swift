import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

// The typed boundary between this feature and the payment Edge Functions.
//
// Nothing above this file builds a URL, and nothing below it knows what a
// checkout screen is. Every payload here is `Codable` and travels through
// `JSONCoding`, so the camelCase properties become the snake_case keys the
// functions read — `orderID` → `order_id`, `hostedCheckoutURL` →
// `hosted_checkout_url` — without a hand-written `CodingKeys` anywhere.

// MARK: - Transport

/// Invokes a PRV Edge Function and returns its raw reply.
///
/// Deliberately narrower than a whole API client: this feature needs exactly
/// one verb — POST a JSON body to `functions/v1/<name>` with the caller's
/// session attached — and narrowing it that far is what makes the live and
/// preview wirings interchangeable in one line.
public protocol PaymentFunctionInvoking: Sendable {
    /// Posts `body` to the named Edge Function and returns its response body.
    ///
    /// - Parameters:
    ///   - name: The function's directory name, e.g. `"create-payment-intent"`.
    ///   - body: An already-encoded JSON payload.
    /// - Throws: `APIError` describing the transport or server failure.
    func invokePaymentFunction(named name: String, body: Data) async throws -> Data
}

extension SupabaseClient: PaymentFunctionInvoking {
    /// Routes payment functions through the shared Supabase client, so a
    /// checkout request presents the same session — and triggers the same
    /// single refresh on a 401 — as every other call the app makes.
    public func invokePaymentFunction(named name: String, body: Data) async throws -> Data {
        try await authData(
            method: .post,
            path: "functions/v1/\(name)",
            body: body,
            authorization: .session
        )
    }
}

/// Routes payment functions through any ``APIClient``.
///
/// The escape hatch for builds that do not use ``SupabaseClient`` — a proxy in
/// front of the functions, a recorded transport in a UI test, a second project
/// during a migration.
public struct APIClientPaymentFunctions: PaymentFunctionInvoking {
    private let client: any APIClient

    /// Wraps an API client.
    public init(client: any APIClient) {
        self.client = client
    }

    /// Posts to `functions/v1/<name>` through the wrapped client.
    public func invokePaymentFunction(named name: String, body: Data) async throws -> Data {
        try await client.send(
            APIRequest(method: .post, path: "functions/v1/\(name)", body: body)
        )
    }
}

// MARK: - Wire payloads

/// The request `create-payment-intent` reads.
///
/// Note what is *not* here: a total. The client states its inputs and the
/// server prices them.
public struct PaymentIntentRequest: Encodable, Hashable, Sendable {
    /// The order to charge against.
    public var orderID: UUID
    /// The deposit level, when the client is not settling in full. Must be one
    /// of `prepayment_policies.offered_percents`; the server rejects any other.
    public var prepaymentPercent: Int?
    /// Whether to vault the instrument for future off-session charges.
    public var savePaymentMethod: Bool
    /// The tip the client added at checkout, in major units of the order's
    /// currency. The server appends it as a `tip` order line before pricing.
    public var tipAmount: Decimal
    /// A gift-card code to spend against this order, applied server-side.
    public var giftCardCode: String?
    /// Whether to spend the client's store credit before charging a method.
    public var applyStoreCredit: Bool
    /// `apple_pay`, `hosted_card`, or `balances_only` — see ``PaymentChannel``.
    public var paymentChannel: String
    /// Where Stripe's hosted page returns control, for `hosted_card` only.
    public var returnURL: URL?

    /// Creates the request body.
    public init(
        orderID: UUID,
        prepaymentPercent: Int?,
        savePaymentMethod: Bool,
        tipAmount: Decimal,
        giftCardCode: String?,
        applyStoreCredit: Bool,
        paymentChannel: String,
        returnURL: URL?
    ) {
        self.orderID = orderID
        self.prepaymentPercent = prepaymentPercent
        self.savePaymentMethod = savePaymentMethod
        self.tipAmount = tipAmount
        self.giftCardCode = giftCardCode
        self.applyStoreCredit = applyStoreCredit
        self.paymentChannel = paymentChannel
        self.returnURL = returnURL
    }
}

/// What `create-payment-intent` answers with.
public struct PaymentIntentEnvelope: Decodable, Hashable, Sendable {
    /// The Stripe PaymentIntent id, e.g. `pi_3Q…`.
    public var paymentIntentID: String
    /// The intent's client secret. Held only for the length of the flow and
    /// never persisted.
    public var clientSecret: String?
    /// The Stripe customer the intent belongs to.
    public var customerID: String?
    /// Stripe's hosted payment page, present when the request asked for the
    /// `hosted_card` channel.
    public var hostedCheckoutURL: URL?
    /// What the server decided to charge — the only authoritative amount.
    public var amount: Money
    /// The gift-card balance the server consumed.
    public var giftCardApplied: Money?
    /// The store credit the server consumed.
    public var storeCreditApplied: Money?
    /// `false` when balances covered the order outright and the server settled
    /// it without creating a charge.
    public var requiresPayment: Bool?
    /// Whether an in-flight intent was reused rather than created.
    public var reused: Bool?

    /// Whether a payment method still has to be charged.
    public var needsCharge: Bool { requiresPayment ?? true }
}

/// The request `confirm-payment-intent` reads for an Apple Pay authorization.
///
/// The token is opaque: it is encrypted to the payment processor's certificate
/// and cannot be decrypted by this app, by the Edge Function, or by anything
/// short of the acquirer. Forwarding it is the whole of the client's job.
public struct ApplePayConfirmationRequest: Encodable, Hashable, Sendable {
    /// The intent being confirmed.
    public var paymentIntentID: String
    /// The order the intent belongs to, so the server can re-check ownership.
    public var orderID: UUID
    /// Base64 of `PKPaymentToken.paymentData`.
    public var applePayToken: String
    /// The card network Apple reported, e.g. `"Visa"`.
    public var paymentNetwork: String?
    /// Apple's transaction identifier, used for deduplication server-side.
    public var transactionIdentifier: String
    /// Billing postcode from the Apple Pay sheet, for address verification.
    public var billingPostalCode: String?
    /// ISO country of the billing address.
    public var billingCountry: String?

    /// Creates the confirmation body.
    public init(
        paymentIntentID: String,
        orderID: UUID,
        applePayToken: String,
        paymentNetwork: String?,
        transactionIdentifier: String,
        billingPostalCode: String?,
        billingCountry: String?
    ) {
        self.paymentIntentID = paymentIntentID
        self.orderID = orderID
        self.applePayToken = applePayToken
        self.paymentNetwork = paymentNetwork
        self.transactionIdentifier = transactionIdentifier
        self.billingPostalCode = billingPostalCode
        self.billingCountry = billingCountry
    }
}

/// What `confirm-payment-intent` answers with.
///
/// The status is used only to decide what the Apple Pay sheet shows the client
/// as it closes. Whether the order is *paid* is answered by the webhook, and
/// read back from the order.
public struct PaymentConfirmationEnvelope: Decodable, Hashable, Sendable {
    /// Stripe's PaymentIntent status: `succeeded`, `processing`,
    /// `requires_action`, `requires_payment_method`, or `failed`.
    public var status: String
    /// A decline reason worth showing, when Stripe gave one.
    public var message: String?

    /// Whether the sheet should close with a tick.
    ///
    /// `processing` counts: an authorization that Stripe has accepted but not
    /// yet captured is a success from the client's point of view, and the
    /// webhook will settle it.
    public var isApproved: Bool {
        status == "succeeded" || status == "processing"
    }
}

/// The request `create-setup-intent` reads when vaulting a card.
public struct CardSetupRequest: Encodable, Hashable, Sendable {
    /// The name to store alongside the vaulted method, for receipts.
    public var cardholderName: String
    /// Billing postcode, used for address verification.
    public var postalCode: String
    /// Whether the vaulted card becomes the client's default method.
    public var setAsDefault: Bool
    /// Where Stripe's hosted setup page returns control.
    public var returnURL: URL

    /// Creates the setup body.
    public init(cardholderName: String, postalCode: String, setAsDefault: Bool, returnURL: URL) {
        self.cardholderName = cardholderName
        self.postalCode = postalCode
        self.setAsDefault = setAsDefault
        self.returnURL = returnURL
    }
}

/// What `create-setup-intent` answers with.
public struct CardSetupEnvelope: Decodable, Hashable, Sendable {
    /// The Stripe SetupIntent id, e.g. `seti_1Q…`.
    public var setupIntentID: String
    /// Stripe's hosted page where the card is entered.
    public var hostedSetupURL: URL
}

/// The `{ "error": { "code", "message" } }` envelope every PRV Edge Function
/// returns on failure.
struct EdgeFunctionErrorEnvelope: Decodable, Sendable {
    /// The error's machine code and human message.
    struct Payload: Decodable, Sendable {
        /// A stable machine code, e.g. `conflict`.
        var code: String
        /// Copy written for the client, safe to show as-is.
        var message: String
    }

    /// The failure the function reported.
    var error: Payload
}

// MARK: - Gateways

/// Creating and confirming payment intents.
public protocol PaymentIntentGateway: Sendable {
    /// Asks the server to price the order and open a PaymentIntent.
    func createPaymentIntent(_ request: PaymentIntentRequest) async throws -> PaymentIntentEnvelope

    /// Forwards an Apple Pay token so the server can confirm the intent.
    func confirmApplePayPayment(
        _ request: ApplePayConfirmationRequest
    ) async throws -> PaymentConfirmationEnvelope
}

/// Vaulting a card without ever seeing it.
public protocol CardVaultGateway: Sendable {
    /// Opens a hosted setup session for a new card.
    func createCardSetup(_ request: CardSetupRequest) async throws -> CardSetupEnvelope

    /// Reads back the method Stripe vaulted for a completed setup intent.
    func vaultedMethod(setupIntentID: String) async throws -> SavedPaymentMethod
}

/// The live gateway: four Edge Functions, no SDK.
public struct EdgeFunctionPaymentGateway: PaymentIntentGateway, CardVaultGateway {
    /// Names of the functions this gateway calls.
    enum Function {
        /// Prices an order and opens a PaymentIntent.
        static let createPaymentIntent = "create-payment-intent"
        /// Confirms an intent with an Apple Pay token.
        static let confirmPaymentIntent = "confirm-payment-intent"
        /// Opens a hosted card-vaulting session.
        static let createSetupIntent = "create-setup-intent"
        /// Reads back the method a completed setup vaulted.
        static let vaultedPaymentMethod = "vaulted-payment-method"
    }

    private let functions: any PaymentFunctionInvoking

    /// Builds the gateway over an Edge Function transport.
    ///
    /// `SupabaseClient` conforms to ``PaymentFunctionInvoking``, so the app
    /// root passes the same client every repository shares.
    public init(functions: any PaymentFunctionInvoking) {
        self.functions = functions
    }

    /// Builds the gateway over a plain ``APIClient``.
    public init(client: any APIClient) {
        self.functions = APIClientPaymentFunctions(client: client)
    }

    /// Asks `create-payment-intent` to price the order and open an intent.
    public func createPaymentIntent(
        _ request: PaymentIntentRequest
    ) async throws -> PaymentIntentEnvelope {
        try await call(Function.createPaymentIntent, body: request)
    }

    /// Hands an Apple Pay token to `confirm-payment-intent`.
    public func confirmApplePayPayment(
        _ request: ApplePayConfirmationRequest
    ) async throws -> PaymentConfirmationEnvelope {
        try await call(Function.confirmPaymentIntent, body: request)
    }

    /// Opens a hosted card-vaulting session through `create-setup-intent`.
    public func createCardSetup(_ request: CardSetupRequest) async throws -> CardSetupEnvelope {
        try await call(Function.createSetupIntent, body: request)
    }

    /// Reads back the vaulted method through `vaulted-payment-method`.
    public func vaultedMethod(setupIntentID: String) async throws -> SavedPaymentMethod {
        try await call(
            Function.vaultedPaymentMethod,
            body: VaultedMethodLookup(setupIntentID: setupIntentID)
        )
    }

    /// The lookup body for a completed setup intent.
    private struct VaultedMethodLookup: Encodable, Sendable {
        /// The setup intent whose vaulted method is wanted.
        let setupIntentID: String
    }

    /// Encodes, invokes, decodes — with both coding failures reported as
    /// `APIError.decoding` rather than leaking `DecodingError` into checkout.
    private func call<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ name: String,
        body: Body
    ) async throws -> Response {
        let payload: Data
        do {
            payload = try JSONCoding.encoder.encode(body)
        } catch {
            throw APIError.decoding("Could not encode the \(name) request: \(error)")
        }

        let data = try await functions.invokePaymentFunction(named: name, body: payload)

        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            PRVLog.payments.error("Could not decode \(name, privacy: .public) response")
            throw APIError.decoding("Could not read the \(name) response: \(error)")
        }
    }
}
