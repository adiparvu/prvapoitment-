import Foundation
import PRVFoundation
import PRVModels

/// The live ``PaymentRepository``, backed by the `saved_payment_methods`,
/// `orders`, `order_lines`, `refunds`, `gift_cards`, `wallet_transactions`, and
/// `invoices` tables plus the `wallet_balances` view.
///
/// Money is never computed on the device. Reads take their arithmetic from the
/// database — an order carries its lines as an embedded resource, a wallet
/// balance is the view's running sum of the append-only ledger — and the one
/// call that moves money, ``pay(orderID:method:amount:)``, goes through the
/// `create-payment-intent` Edge Function, which re-derives the chargeable figure
/// from the lines under the caller's own RLS. This repository then re-reads the
/// order and returns what the server says it is.
///
/// Row Level Security (`0002_rls.sql`) already scopes what each caller may see
/// and change, so no method re-implements authorization: an order is
/// client-writable only while it is a `draft`, the wallet ledger has no write
/// policy at all, and a refund may only be inserted by a holder of
/// `manageRefunds`.
public struct SupabasePaymentRepository: PaymentRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns, so one careless filter can
    /// never page an entire table into memory.
    private static let listLimit = 100

    /// The order projection: the row plus the lines its value type absorbs.
    private static let orderColumns = "*,order_lines(*)"
    /// Invoices are scoped by joining their order, so the filter and the RLS
    /// policy agree by construction rather than by coincidence.
    private static let invoiceColumns = "*,orders!inner(client_id)"
    /// Only the two sums store credit is made of are read from the view.
    private static let walletBalanceColumns = "user_id,currency,cashback_amount,store_credit_amount"

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Methods & orders

    /// Every payment method the user has saved, oldest first.
    ///
    /// `saved_payment_methods` stores Stripe tokens and display metadata only —
    /// a PAN never reaches this table, and never reaches the device either.
    public func savedMethods(userID: User.ID) async throws -> [SavedPaymentMethod] {
        let request = PostgRESTQuery("saved_payment_methods")
            .filter(.equals("user_id", userID.rawValue))
            .order("created_at")
            .limited(to: Self.listLimit)
        let rows: [SavedPaymentMethodRow] = try await client.select(request)
        return rows.map(Self.makeSavedMethod)
    }

    /// The client's orders, newest first, each with its lines.
    public func orders(clientID: User.ID) async throws -> [Order] {
        let request = PostgRESTQuery("orders")
            .selecting(Self.orderColumns)
            .filter(.equals("client_id", clientID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [OrderRow] = try await client.select(request)
        return try rows.map(Self.makeOrder)
    }

    /// One order with its lines.
    public func order(id: Order.ID) async throws -> Order {
        let request = PostgRESTQuery("orders")
            .selecting(Self.orderColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: OrderRow = try await client.select(request)
        return try Self.makeOrder(row)
    }

    /// Creates an order and its lines, then returns the order as stored.
    ///
    /// The order is always written as a `draft` first, whatever status was asked
    /// for: `order_lines` is writable by a client only while its order is a
    /// draft (`order_lines_write_participant`), so composing the basket and then
    /// promoting it is the one ordering RLS permits. Totals are never sent —
    /// `order_totals` derives them from the lines — and `created_at` is left to
    /// the database, which is the single clock.
    public func createOrder(_ order: Order) async throws -> Order {
        let payload = OrderInsert(
            id: order.id.rawValue,
            salonID: order.salonID.rawValue,
            clientID: order.clientID.rawValue,
            appointmentID: order.appointmentID?.rawValue,
            status: OrderStatus.draft.rawValue,
            discountAmount: order.discount.amount,
            discountReason: order.discountReason,
            vatPercent: order.vatPercent,
            amountPaid: order.amountPaid.amount,
            pointsEarned: order.pointsEarned,
            currency: order.currency.rawValue
        )
        let created: OrderIdentifierRow = try await client.insert(
            into: "orders",
            values: payload,
            returning: "id"
        )

        if !order.lines.isEmpty {
            let lines = order.lines.enumerated().map { index, line in
                OrderLineInsert(
                    id: line.id.rawValue,
                    orderID: created.id,
                    kind: line.kind.rawValue,
                    title: line.title,
                    quantity: line.quantity,
                    unitPrice: line.unitPrice.amount,
                    currency: line.unitPrice.currency.rawValue,
                    referenceID: line.referenceID,
                    position: index
                )
            }
            _ = try await client.insert(
                into: "order_lines",
                values: lines,
                returning: "id",
                singleRow: false,
                as: [OrderLineIdentifierRow].self
            )
        }

        if order.status != .draft {
            _ = try await client.update(
                "orders",
                values: OrderStatusUpdate(status: order.status.rawValue),
                filters: [.equals("id", created.id)],
                returning: "id",
                as: OrderIdentifierRow.self
            )
        }

        return try await self.order(id: Order.ID(created.id))
    }

    // MARK: - Paying

    /// Charges `amount` against the order and returns the order as the server
    /// reports it afterwards.
    ///
    /// Nothing here mutates the order. `create-payment-intent` reads it under
    /// the caller's JWT, re-derives the payable figure from the lines, applies
    /// the salon's prepayment rules, and creates — or idempotently reuses — a
    /// Stripe PaymentIntent, so a retried tap resolves to the same intent rather
    /// than a second charge. `amount` is therefore a statement of intent, not an
    /// instruction: it selects a prepayment level when it is a genuine deposit,
    /// and is otherwise ignored in favour of the server's own outstanding
    /// balance.
    ///
    /// The order comes back `awaiting_payment` with an intent attached. It
    /// becomes `paid` once Stripe confirms and `stripe-webhook` settles it — a
    /// device never writes `amount_paid`.
    ///
    /// Tenders Stripe does not settle — gift card, store credit, cash at the
    /// salon — have no client-callable path: `wallet_transactions` has no write
    /// policy and a non-draft `orders` row is writable only by the salon or by
    /// an Edge Function. Sending one here would raise a card intent for money
    /// that is not coming from a card, so it is refused instead of quietly
    /// double-charging.
    public func pay(orderID: Order.ID, method: PaymentMethodKind, amount: Money) async throws -> Order {
        guard Self.isStripeSettled(method) else {
            throw APIError.conflict("\(method.displayName) is settled by the salon, not from the app.")
        }

        let current = try await order(id: orderID)
        let response: PaymentIntentResponse = try await client.invoke(
            function: "create-payment-intent",
            body: PaymentIntentRequest(
                orderID: orderID.rawValue,
                prepaymentPercent: Self.prepaymentPercent(paying: amount, on: current),
                savePaymentMethod: false
            )
        )
        PRVLog.payments.info(
            "Payment intent \(response.paymentIntentID, privacy: .public) ready for order \(orderID.description, privacy: .public)"
        )

        return try await order(id: orderID)
    }

    /// Whether Stripe settles this tender.
    ///
    /// Listed exhaustively rather than defaulted, so a new payment method has to
    /// declare which side of the line it falls on.
    private static func isStripeSettled(_ kind: PaymentMethodKind) -> Bool {
        switch kind {
        case .applePay, .card, .bancontact, .payPal: true
        case .giftCard, .storeCredit, .cashOnSite: false
        }
    }

    /// The prepayment level `amount` represents, or `nil` when it settles the
    /// outstanding balance outright.
    ///
    /// A deposit is expressed to the Edge Function as a percentage of the order
    /// rather than as a figure, because the salon publishes the levels it
    /// accepts (`prepayment_policies.offered_percents`) and the server rejects
    /// anything else — a client cannot invent a 5% deposit. Rounding is
    /// banker's, matching `PRVPaymentsKit`, so the level quoted before the tap
    /// is the level the server prices.
    private static func prepaymentPercent(paying amount: Money, on order: Order) -> Int? {
        guard amount < order.outstandingBalance else { return nil }
        let total = order.total.amount
        guard total > 0 else { return nil }

        let covered = order.amountPaid.amount + amount.amount
        let level = NSDecimalNumber(decimal: (covered * 100 / total).rounded(scale: 0)).intValue
        guard level > 0, level < 100 else { return nil }
        return level
    }

    // MARK: - Refunds

    /// Refunds recorded against an order, oldest first.
    public func refunds(orderID: Order.ID) async throws -> [Refund] {
        let request = PostgRESTQuery("refunds")
            .filter(.equals("order_id", orderID.rawValue))
            .order("created_at")
            .limited(to: Self.listLimit)
        let rows: [RefundRow] = try await client.select(request)
        return try rows.map(Self.makeRefund)
    }

    /// Records a refund against an order.
    ///
    /// This writes the `refunds` row directly rather than calling an Edge
    /// Function, because the one that issues refunds — `cancel-appointment` — is
    /// a different operation wearing a similar name: it is keyed on an
    /// appointment, derives the amount from the salon's cancellation policy, and
    /// cancels the booking as a side effect. A ``Refund`` carries an explicit
    /// amount and reason and cancels nothing, so routing it there would ignore
    /// the amount and cancel an appointment nobody asked to cancel.
    ///
    /// `refunds_insert_authorized` restricts this to staff holding
    /// `manageRefunds` on the order's salon, which is exactly the manual,
    /// authorized refund this call models. Money leaves through Stripe;
    /// `stripe-webhook` records the settlement against `stripe_refund_id` and
    /// reconciles `orders.status` to `refunded` or `partially_refunded`, which is
    /// why the order is not touched here.
    public func requestRefund(_ refund: Refund) async throws -> Refund {
        let payload = RefundInsert(
            id: refund.id.rawValue,
            orderID: refund.orderID.rawValue,
            amount: refund.amount.amount,
            currency: refund.amount.currency.rawValue,
            reason: refund.reason.rawValue,
            note: refund.note,
            isAutomatic: refund.isAutomatic
        )
        let row: RefundRow = try await client.insert(into: "refunds", values: payload)
        return try Self.makeRefund(row)
    }

    // MARK: - Gift cards

    /// Gift cards the user bought, oldest first.
    ///
    /// RLS scopes this to the purchaser and to staff of the issuing salon, so a
    /// card bought as a present stays visible to the person who paid for it.
    public func giftCards(userID: User.ID) async throws -> [GiftCard] {
        let request = PostgRESTQuery("gift_cards")
            .filter(.equals("purchaser_id", userID.rawValue))
            .order("created_at")
            .limited(to: Self.listLimit)
        let rows: [GiftCardRow] = try await client.select(request)
        return try rows.map(Self.makeGiftCard)
    }

    /// Issues a gift card and returns it as stored.
    public func purchaseGiftCard(_ card: GiftCard) async throws -> GiftCard {
        let payload = GiftCardInsert(
            id: card.id.rawValue,
            code: card.code,
            salonID: card.salonID?.rawValue,
            initialBalance: card.initialBalance.amount,
            remainingBalance: card.remainingBalance.amount,
            currency: card.initialBalance.currency.rawValue,
            purchaserID: card.purchaserID?.rawValue,
            recipientEmail: card.recipientEmail,
            message: card.message,
            expiresAt: card.expiresAt.map(SupabaseTimestamp.string(from:))
        )
        let row: GiftCardRow = try await client.insert(into: "gift_cards", values: payload)
        return try Self.makeGiftCard(row)
    }

    /// Looks a gift card up by its printed code.
    ///
    /// The match is exact rather than `ilike`: codes are stored uppercase and
    /// normalized by the checkout before they arrive here, and a pattern match
    /// would let a `%` behave as a wildcard across every card the caller can
    /// read.
    public func redeemGiftCard(code: String) async throws -> GiftCard {
        let request = PostgRESTQuery("gift_cards")
            .filter(.equals("code", code))
            .single()
        let row: GiftCardRow = try await client.select(request)
        return try Self.makeGiftCard(row)
    }

    // MARK: - Wallet & invoices

    /// The user's Beauty Wallet ledger, newest first.
    public func walletTransactions(userID: User.ID) async throws -> [WalletTransaction] {
        let request = PostgRESTQuery("wallet_transactions")
            .filter(.equals("user_id", userID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [WalletTransactionRow] = try await client.select(request)
        return try rows.map(Self.makeWalletTransaction)
    }

    /// Invoices issued for the user's own orders, oldest first.
    public func invoices(userID: User.ID) async throws -> [Invoice] {
        let request = PostgRESTQuery("invoices")
            .selecting(Self.invoiceColumns)
            .filter(.equals("orders.client_id", userID.rawValue))
            .order("issued_at")
            .limited(to: Self.listLimit)
        let rows: [InvoiceRow] = try await client.select(request)
        return try rows.map(Self.makeInvoice)
    }

    /// Spendable store credit: cashback plus store-credit movements.
    ///
    /// Read from the `wallet_balances` view rather than summed on the device.
    /// The view aggregates the append-only ledger inside the database, under the
    /// caller's own RLS, and groups by currency — so a wallet that has only ever
    /// held euros reduces cleanly from a zero seed, and one that has held two
    /// currencies is not silently added together into a third.
    public func storeCreditBalance(userID: User.ID) async throws -> Money {
        let request = PostgRESTQuery("wallet_balances")
            .selecting(Self.walletBalanceColumns)
            .filter(.equals("user_id", userID.rawValue))
        let rows: [WalletBalanceRow] = try await client.select(request)
        return rows.reduce(Money.zero()) { running, row in
            let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
            let credit = (row.cashbackAmount ?? 0) + (row.storeCreditAmount ?? 0)
            return running + Money(credit, currency)
        }
    }

    // MARK: - Row mapping

    private static func makeSavedMethod(_ row: SavedPaymentMethodRow) -> SavedPaymentMethod {
        SavedPaymentMethod(
            id: SavedPaymentMethod.ID(row.id),
            kind: PaymentMethodKind(rawValue: row.kind) ?? .card,
            displayLabel: row.displayLabel,
            lastFour: row.lastFour?.trimmed,
            expiryMonth: row.expiryMonth,
            expiryYear: row.expiryYear,
            isDefault: row.isDefault
        )
    }

    private static func makeOrder(_ row: OrderRow) throws -> Order {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        let lines = (row.orderLines?.values ?? [])
            .sorted { $0.position < $1.position }
            .map { line in
                OrderLine(
                    id: OrderLine.ID(line.id),
                    kind: OrderLine.Kind(rawValue: line.kind) ?? .service,
                    title: line.title,
                    quantity: line.quantity,
                    unitPrice: Money(line.unitPrice, Currency(rawValue: line.currency.trimmed) ?? currency),
                    referenceID: line.referenceID
                )
            }
        return Order(
            id: Order.ID(row.id),
            salonID: Salon.ID(row.salonID),
            clientID: User.ID(row.clientID),
            appointmentID: row.appointmentID.map { Appointment.ID($0) },
            lines: lines,
            status: OrderStatus(rawValue: row.status) ?? .draft,
            discount: Money(row.discountAmount, currency),
            discountReason: row.discountReason,
            vatPercent: row.vatPercent,
            amountPaid: Money(row.amountPaid, currency),
            pointsEarned: row.pointsEarned,
            currency: currency,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt),
            paidAt: SupabaseTimestamp.optionalDate(from: row.paidAt)
        )
    }

    private static func makeRefund(_ row: RefundRow) throws -> Refund {
        Refund(
            id: Refund.ID(row.id),
            orderID: Order.ID(row.orderID),
            amount: Money(row.amount, Currency(rawValue: row.currency.trimmed) ?? .eur),
            reason: Refund.Reason(rawValue: row.reason) ?? .cancellation,
            note: row.note,
            isAutomatic: row.isAutomatic,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }

    private static func makeGiftCard(_ row: GiftCardRow) throws -> GiftCard {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        return GiftCard(
            id: GiftCard.ID(row.id),
            code: row.code,
            salonID: row.salonID.map { Salon.ID($0) },
            initialBalance: Money(row.initialBalance, currency),
            remainingBalance: Money(row.remainingBalance, currency),
            purchaserID: row.purchaserID.map { User.ID($0) },
            recipientEmail: row.recipientEmail,
            message: row.message,
            expiresAt: SupabaseTimestamp.optionalDate(from: row.expiresAt),
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }

    private static func makeWalletTransaction(_ row: WalletTransactionRow) throws -> WalletTransaction {
        WalletTransaction(
            id: WalletTransaction.ID(row.id),
            userID: User.ID(row.userID),
            kind: WalletTransaction.Kind(rawValue: row.kind) ?? .payment,
            amount: Money(row.amount, Currency(rawValue: row.currency.trimmed) ?? .eur),
            points: row.points,
            title: row.title,
            orderID: row.orderID.map { Order.ID($0) },
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }

    private static func makeInvoice(_ row: InvoiceRow) throws -> Invoice {
        Invoice(
            id: Invoice.ID(row.id),
            orderID: Order.ID(row.orderID),
            number: row.number,
            issuedAt: try SupabaseTimestamp.date(from: row.issuedAt),
            pdfURL: row.pdfURL.flatMap(URL.init(string:))
        )
    }
}

// MARK: - Rows

extension SupabasePaymentRepository {
    /// A `saved_payment_methods` row.
    fileprivate struct SavedPaymentMethodRow: Decodable, Sendable {
        let id: UUID
        let kind: String
        let displayLabel: String
        let lastFour: String?
        let expiryMonth: Int?
        let expiryYear: Int?
        let isDefault: Bool
    }

    /// An `orders` row plus its embedded lines.
    fileprivate struct OrderRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let clientID: UUID
        let appointmentID: UUID?
        let status: String
        let discountAmount: Decimal
        let discountReason: String?
        let vatPercent: Decimal
        let amountPaid: Decimal
        let pointsEarned: Int
        let currency: String
        let createdAt: String
        let paidAt: String?
        let orderLines: SupabaseEmbedded<OrderLineRow>?
    }

    /// An `order_lines` row.
    fileprivate struct OrderLineRow: Decodable, Sendable {
        let id: UUID
        let kind: String
        let title: String
        let quantity: Int
        let unitPrice: Decimal
        let currency: String
        let referenceID: UUID?
        let position: Int
    }

    /// The identifier PostgREST echoes back from an `orders` write.
    fileprivate struct OrderIdentifierRow: Decodable, Sendable {
        let id: UUID
    }

    /// The identifier PostgREST echoes back from an `order_lines` write.
    fileprivate struct OrderLineIdentifierRow: Decodable, Sendable {
        let id: UUID
    }

    /// A `refunds` row.
    fileprivate struct RefundRow: Decodable, Sendable {
        let id: UUID
        let orderID: UUID
        let amount: Decimal
        let currency: String
        let reason: String
        let note: String?
        let isAutomatic: Bool
        let createdAt: String
    }

    /// A `gift_cards` row.
    fileprivate struct GiftCardRow: Decodable, Sendable {
        let id: UUID
        let code: String
        let salonID: UUID?
        let initialBalance: Decimal
        let remainingBalance: Decimal
        let currency: String
        let purchaserID: UUID?
        let recipientEmail: String?
        let message: String?
        let expiresAt: String?
        let createdAt: String
    }

    /// A `wallet_transactions` row.
    fileprivate struct WalletTransactionRow: Decodable, Sendable {
        let id: UUID
        let userID: UUID
        let kind: String
        let amount: Decimal
        let currency: String
        let points: Int
        let title: String
        let orderID: UUID?
        let createdAt: String
    }

    /// An `invoices` row. The `orders` embed exists only so the ownership filter
    /// becomes a join; its contents are never read.
    fileprivate struct InvoiceRow: Decodable, Sendable {
        let id: UUID
        let orderID: UUID
        let number: String
        let issuedAt: String
        let pdfURL: String?
    }

    /// A `wallet_balances` row. The filtered sums are `NULL` when the ledger
    /// holds nothing of that kind.
    fileprivate struct WalletBalanceRow: Decodable, Sendable {
        let currency: String
        let cashbackAmount: Decimal?
        let storeCreditAmount: Decimal?
    }
}

// MARK: - Payloads

extension SupabasePaymentRepository {
    /// The columns a new order supplies. Totals, `created_at`, and the Stripe
    /// identifiers are all server-owned.
    fileprivate struct OrderInsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let clientID: UUID
        let appointmentID: UUID?
        let status: String
        let discountAmount: Decimal
        let discountReason: String?
        let vatPercent: Decimal
        let amountPaid: Decimal
        let pointsEarned: Int
        let currency: String
    }

    /// A new `order_lines` row.
    fileprivate struct OrderLineInsert: Encodable, Sendable {
        let id: UUID
        let orderID: UUID
        let kind: String
        let title: String
        let quantity: Int
        let unitPrice: Decimal
        let currency: String
        let referenceID: UUID?
        let position: Int
    }

    /// Promotes a freshly composed draft to the status the caller asked for.
    fileprivate struct OrderStatusUpdate: Encodable, Sendable {
        let status: String
    }

    /// A new `refunds` row. `created_at` is the database's and `created_by` the
    /// JWT's.
    fileprivate struct RefundInsert: Encodable, Sendable {
        let id: UUID
        let orderID: UUID
        let amount: Decimal
        let currency: String
        let reason: String
        let note: String?
        let isAutomatic: Bool
    }

    /// A new `gift_cards` row.
    fileprivate struct GiftCardInsert: Encodable, Sendable {
        let id: UUID
        let code: String
        let salonID: UUID?
        let initialBalance: Decimal
        let remainingBalance: Decimal
        let currency: String
        let purchaserID: UUID?
        let recipientEmail: String?
        let message: String?
        let expiresAt: String?
    }

    /// The `create-payment-intent` request body.
    fileprivate struct PaymentIntentRequest: Encodable, Sendable {
        let orderID: UUID
        let prepaymentPercent: Int?
        let savePaymentMethod: Bool
    }

    /// The `create-payment-intent` response.
    ///
    /// Only the intent identifier is read. The amount is re-read from the order
    /// rather than trusted from a response body, and the client secret,
    /// customer, and ephemeral key the function also returns have nowhere to go:
    /// `PaymentRepository.pay` answers with an `Order`, so confirming the intent
    /// with Stripe's sheet needs a channel this protocol does not have.
    fileprivate struct PaymentIntentResponse: Decodable, Sendable {
        let paymentIntentID: String
    }
}
