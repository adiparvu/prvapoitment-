import Foundation
import PRVFoundation
import PRVModels

/// The live ``InventoryRepository``, backed by the `products`, `suppliers`,
/// `purchase_orders`, and `purchase_order_lines` tables.
///
/// Inventory is never public: `0002_rls.sql` scopes `products` to salon members
/// and its writes to `manageInventory`, because cost prices are commercially
/// sensitive. Stock is not adjusted here either — `products.stock_quantity` is
/// written like any other column and the `notify_low_stock` trigger in
/// `0003_functions_triggers.sql` is what turns a dip below the threshold into a
/// notification, so the reorder prompt arrives whether the change came from the
/// app, the till, or a back-office import.
///
/// A purchase order absorbs its lines, which are embedded on every read so an
/// order list is a single round trip.
public struct SupabaseInventoryRepository: InventoryRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns.
    private static let listLimit = 200

    /// The purchase-order projection: the row plus the lines it absorbs.
    private static let purchaseOrderColumns = "*,purchase_order_lines(*)"

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Products

    /// The salon's catalogue, alphabetically.
    ///
    /// Deactivated products are not filtered out, for the same reason
    /// ``SupabaseSalonRepository/services(salonID:)`` keeps inactive services:
    /// `Product` carries no `isActive`, so a product hidden here could never be
    /// brought back from the app, and `products_select_staff` already limits the
    /// whole table to salon members.
    public func products(salonID: Salon.ID) async throws -> [Product] {
        let request = PostgRESTQuery("products")
            .filter(.equals("salon_id", salonID.rawValue))
            .order("name")
            .limited(to: Self.listLimit)
        let rows: [ProductRow] = try await client.select(request)
        return rows.map(Self.makeProduct)
    }

    /// Creates or replaces a product, returning it as stored.
    ///
    /// The upsert resolves on the primary key, so the same call serves the "new
    /// product" sheet, an inline stock adjustment, and folding a received
    /// purchase order back into stock. `is_active` is never sent — `Product` has
    /// no such property, so a deactivated product stays deactivated rather than
    /// being silently revived by an unrelated edit.
    public func upsertProduct(_ product: Product) async throws -> Product {
        let payload = ProductUpsert(
            id: product.id.rawValue,
            salonID: product.salonID.rawValue,
            supplierID: SupabaseNullableColumn(product.supplierID?.rawValue),
            name: product.name,
            brand: product.brand,
            details: product.details,
            barcode: SupabaseNullableColumn(product.barcode),
            retailPriceAmount: product.retailPrice.amount,
            costPriceAmount: product.costPrice.amount,
            currency: product.retailPrice.currency.rawValue,
            stockQuantity: product.stockQuantity,
            lowStockThreshold: product.lowStockThreshold,
            expiresAt: SupabaseNullableColumn(product.expiresAt.map(SupabaseTimestamp.string(from:))),
            imageURL: SupabaseNullableColumn(product.imageURL?.absoluteString),
            isRetail: product.isRetail
        )
        let row: ProductRow = try await client.upsert(
            into: "products",
            values: payload,
            onConflict: "id"
        )
        return Self.makeProduct(row)
    }

    /// The product a scanned barcode resolves to within one salon.
    ///
    /// Barcodes are unique per salon (`products_barcode_key`), never globally,
    /// so both halves of the key are filtered on and the query asks for exactly
    /// one row — "nothing scanned" arrives as ``APIError/notFound``, which is
    /// what `InMemoryBackend` throws and what the scanner sheet expects.
    public func product(barcode: String, salonID: Salon.ID) async throws -> Product {
        let row: ProductRow = try await client.select(
            PostgRESTQuery("products")
                .filter(.equals("salon_id", salonID.rawValue))
                .filter(.equals("barcode", barcode.trimmed))
                .single()
        )
        return Self.makeProduct(row)
    }

    // MARK: - Suppliers

    /// Every supplier the caller can see, alphabetically.
    ///
    /// `Supplier` has no salon of its own, so nothing is filtered here:
    /// `suppliers_select_staff` already returns the platform-wide suppliers
    /// (`salon_id is null`) plus the ones belonging to salons the caller works
    /// at, which is exactly the list a purchase order may be raised against.
    public func suppliers() async throws -> [Supplier] {
        let request = PostgRESTQuery("suppliers")
            .order("name")
            .limited(to: Self.listLimit)
        let rows: [SupplierRow] = try await client.select(request)
        return rows.map(Self.makeSupplier)
    }

    // MARK: - Purchase orders

    /// The salon's purchase orders, newest first, with their lines.
    public func purchaseOrders(salonID: Salon.ID) async throws -> [PurchaseOrder] {
        let request = PostgRESTQuery("purchase_orders")
            .selecting(Self.purchaseOrderColumns)
            .filter(.equals("salon_id", salonID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [PurchaseOrderRow] = try await client.select(request)
        return try rows.map { try Self.makePurchaseOrder($0) }
    }

    /// Creates or replaces a purchase order and its lines, returning it as stored.
    ///
    /// `PurchaseOrder.Line` has no identity of its own — it is a
    /// `(product, quantity, unit cost)` triple — so the lines cannot be matched
    /// up one by one against what is already stored. They are therefore replaced
    /// wholesale: the order's existing lines are deleted and the submitted set is
    /// written back in order, which is the only reconciliation that reproduces
    /// `InMemoryBackend`'s "replace the element" semantics without inventing a
    /// line identifier the domain model does not have.
    ///
    /// `received_at` is stamped only on the transition into `received`, because
    /// the `purchase_orders_received_consistency` constraint requires it there
    /// and nothing else may move it afterwards. `created_at` is left to the
    /// database.
    public func upsertPurchaseOrder(_ order: PurchaseOrder) async throws -> PurchaseOrder {
        let payload = PurchaseOrderUpsert(
            id: order.id.rawValue,
            salonID: order.salonID.rawValue,
            supplierID: order.supplierID.rawValue,
            status: order.status.rawValue,
            currency: order.totalCost.currency.rawValue,
            expectedAt: SupabaseNullableColumn(order.expectedAt.map(SupabaseTimestamp.string(from:))),
            receivedAt: order.status == .received ? SupabaseTimestamp.string(from: .now) : nil
        )
        let stored: PurchaseOrderRow = try await client.upsert(
            into: "purchase_orders",
            values: payload,
            onConflict: "id"
        )

        try await client.deleteRows(
            from: "purchase_order_lines",
            filters: [.equals("purchase_order_id", stored.id)]
        )

        var storedLines: [PurchaseOrderLineRow] = []
        if !order.lines.isEmpty {
            let lines = order.lines.enumerated().map { index, line in
                PurchaseOrderLineInsert(
                    purchaseOrderID: stored.id,
                    productID: line.productID.rawValue,
                    productName: line.productName,
                    quantity: line.quantity,
                    unitCostAmount: line.unitCost.amount,
                    currency: line.unitCost.currency.rawValue,
                    position: index
                )
            }
            storedLines = try await client.insert(
                into: "purchase_order_lines",
                values: lines,
                singleRow: false,
                as: [PurchaseOrderLineRow].self
            )
        }

        return try Self.makePurchaseOrder(stored, lines: storedLines)
    }

    // MARK: - Row mapping

    private static func makeProduct(_ row: ProductRow) -> Product {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        return Product(
            id: Product.ID(row.id),
            salonID: Salon.ID(row.salonID),
            name: row.name,
            brand: row.brand,
            details: row.details,
            barcode: row.barcode,
            retailPrice: Money(row.retailPriceAmount, currency),
            costPrice: Money(row.costPriceAmount, currency),
            stockQuantity: row.stockQuantity,
            lowStockThreshold: row.lowStockThreshold,
            expiresAt: SupabaseTimestamp.optionalDate(from: row.expiresAt),
            supplierID: row.supplierID.map { Supplier.ID($0) },
            imageURL: row.imageURL.flatMap(URL.init(string:)),
            isRetail: row.isRetail
        )
    }

    private static func makeSupplier(_ row: SupplierRow) -> Supplier {
        Supplier(
            id: Supplier.ID(row.id),
            name: row.name,
            email: row.email,
            phone: row.phone
        )
    }

    private static func makePurchaseOrder(_ row: PurchaseOrderRow) throws -> PurchaseOrder {
        try makePurchaseOrder(row, lines: row.purchaseOrderLines?.values ?? [])
    }

    private static func makePurchaseOrder(
        _ row: PurchaseOrderRow,
        lines: [PurchaseOrderLineRow]
    ) throws -> PurchaseOrder {
        let orderCurrency = Currency(rawValue: row.currency.trimmed) ?? .eur
        let orderedLines = lines
            .sorted { $0.position < $1.position }
            .map { line in
                PurchaseOrder.Line(
                    productID: Product.ID(line.productID),
                    productName: line.productName,
                    quantity: line.quantity,
                    unitCost: Money(
                        line.unitCostAmount,
                        Currency(rawValue: line.currency.trimmed) ?? orderCurrency
                    )
                )
            }
        return PurchaseOrder(
            id: PurchaseOrder.ID(row.id),
            salonID: Salon.ID(row.salonID),
            supplierID: Supplier.ID(row.supplierID),
            lines: orderedLines,
            status: PurchaseOrder.Status(rawValue: row.status) ?? .draft,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt),
            expectedAt: SupabaseTimestamp.optionalDate(from: row.expectedAt)
        )
    }
}

// MARK: - Rows

extension SupabaseInventoryRepository {
    /// A `products` row.
    fileprivate struct ProductRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let supplierID: UUID?
        let name: String
        let brand: String
        let details: String
        let barcode: String?
        let retailPriceAmount: Decimal
        let costPriceAmount: Decimal
        let currency: String
        let stockQuantity: Int
        let lowStockThreshold: Int
        let expiresAt: String?
        let imageURL: String?
        let isRetail: Bool
    }

    /// A `suppliers` row.
    fileprivate struct SupplierRow: Decodable, Sendable {
        let id: UUID
        let name: String
        let email: String?
        let phone: String?
    }

    /// A `purchase_orders` row plus its embedded lines.
    fileprivate struct PurchaseOrderRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let supplierID: UUID
        let status: String
        let currency: String
        let expectedAt: String?
        let createdAt: String
        let purchaseOrderLines: SupabaseEmbedded<PurchaseOrderLineRow>?
    }

    /// A `purchase_order_lines` row.
    fileprivate struct PurchaseOrderLineRow: Decodable, Sendable {
        let productID: UUID
        let productName: String
        let quantity: Int
        let unitCostAmount: Decimal
        let currency: String
        let position: Int
    }
}

// MARK: - Payloads

extension SupabaseInventoryRepository {
    /// A whole product, merged onto the primary key.
    fileprivate struct ProductUpsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let supplierID: SupabaseNullableColumn<UUID>
        let name: String
        let brand: String
        let details: String
        let barcode: SupabaseNullableColumn<String>
        let retailPriceAmount: Decimal
        let costPriceAmount: Decimal
        let currency: String
        let stockQuantity: Int
        let lowStockThreshold: Int
        let expiresAt: SupabaseNullableColumn<String>
        let imageURL: SupabaseNullableColumn<String>
        let isRetail: Bool
    }

    /// A whole purchase order, merged onto the primary key.
    fileprivate struct PurchaseOrderUpsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let supplierID: UUID
        let status: String
        let currency: String
        let expectedAt: SupabaseNullableColumn<String>
        /// Sent only on the transition into `received`, so an order that was
        /// already received keeps the instant it actually arrived.
        let receivedAt: String?
    }

    /// One replacement `purchase_order_lines` row.
    fileprivate struct PurchaseOrderLineInsert: Encodable, Sendable {
        let purchaseOrderID: UUID
        let productID: UUID
        let productName: String
        let quantity: Int
        let unitCostAmount: Decimal
        let currency: String
        let position: Int
    }
}
