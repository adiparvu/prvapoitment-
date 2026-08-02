import Foundation
import Observation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Rules

/// Thresholds the stock desk works to. Kept outside the model so views can read
/// them without hopping actors.
enum InventoryRules {
    /// Products expiring within this many days get a badge.
    static let expiryWarningDays = 60
    /// How long the stepper waits before writing a stock change through.
    static let stockWriteDelay = Duration.milliseconds(450)
}

// MARK: - Tabs

/// The two halves of the Inventory desk.
enum InventoryTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case stock
    case orders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stock: "Stock"
        case .orders: "Orders"
        }
    }
}

// MARK: - Purchase order draft

/// The editable shape of a purchase order, used by the new-order sheet.
struct PurchaseOrderDraft: Hashable, Sendable {
    var supplierID: Supplier.ID?
    var expectedAt: Date
    var lines: [PurchaseOrder.Line]

    init(
        supplierID: Supplier.ID? = nil,
        expectedAt: Date = Date.now.adding(days: 7),
        lines: [PurchaseOrder.Line] = []
    ) {
        self.supplierID = supplierID
        self.expectedAt = expectedAt
        self.lines = lines
    }

    /// An order needs a supplier and at least one line before it can be sent.
    var isValid: Bool { supplierID != nil && !lines.isEmpty }

    /// Running total of every line, in the currency the lines are priced in.
    var total: Money {
        guard let currency = lines.first?.unitCost.currency else { return .zero() }
        return lines.reduce(Money.zero(currency)) { $0 + ($1.unitCost * Decimal($1.quantity)) }
    }

    /// Total units on the order.
    var unitCount: Int { lines.reduce(0) { $0 + $1.quantity } }

    /// Materializes the draft. New orders are created as `.sent` — the studio
    /// builds them to place them; a draft that is never sent has no value.
    func order(salonID: Salon.ID) -> PurchaseOrder? {
        guard let supplierID else { return nil }
        return PurchaseOrder(
            salonID: salonID,
            supplierID: supplierID,
            lines: lines,
            status: .sent,
            expectedAt: expectedAt
        )
    }
}

// MARK: - Model

/// Screen model behind ``InventoryView``.
///
/// Holds the salon's stock, its suppliers, and its purchase orders. Stock
/// adjustments are optimistic and debounced: the stepper moves instantly, and
/// the write to `upsertProduct` follows once the person stops tapping, so a run
/// of taps becomes one round trip instead of ten.
@Observable
@MainActor
final class InventoryModel {
    // MARK: Selection

    var tab: InventoryTab = .stock
    var searchText = ""
    /// Active brand filter chip, `nil` for "All brands".
    var selectedBrand: String?

    // MARK: Barcode

    var barcodeQuery = ""
    private(set) var barcodeResult: Product?
    private(set) var isLookingUp = false
    /// Presents the VisionKit scanner sheet.
    var isPresentingScanner = false
    /// Presents the new purchase-order sheet.
    var isPresentingNewOrder = false

    // MARK: State

    private(set) var phase: OperationsPhase = .loading
    private(set) var salon: Salon?
    private(set) var products: [Product] = []
    private(set) var suppliers: [Supplier] = []
    private(set) var purchaseOrders: [PurchaseOrder] = []
    private(set) var ordersError: String?

    /// Optimistic stock values while a debounced write is pending.
    private(set) var pendingStock: [Product.ID: Int] = [:]
    private(set) var savingProductIDs: Set<Product.ID> = []
    private(set) var receivingOrderIDs: Set<PurchaseOrder.ID> = []
    private(set) var isSavingOrder = false

    var toast: PRVToast?
    private(set) var hasLoadedOnce = false

    private var stockWrites: [Product.ID: Task<Void, Never>] = [:]
    private let calendar = Calendar.current

    // MARK: Derived

    /// Currency of the salon being operated (falls back to euro).
    var currency: Currency { salon?.currency ?? .eur }

    /// Every brand in stock, alphabetically, for the filter chips.
    var brands: [String] {
        Array(Set(products.map(\.brand)))
            .filter { !$0.isBlank }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Products matching the search text and brand chip.
    var filteredProducts: [Product] {
        let query = searchText.trimmed
        return products
            .filter { product in
                guard selectedBrand == nil || product.brand == selectedBrand else { return false }
                guard !query.isEmpty else { return true }
                return product.name.localizedCaseInsensitiveContains(query)
                    || product.brand.localizedCaseInsensitiveContains(query)
                    || product.details.localizedCaseInsensitiveContains(query)
                    || (product.barcode?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Low-stock matches, pinned above everything else.
    var lowStockProducts: [Product] {
        filteredProducts.filter(\.isLowStock)
    }

    /// Healthy-stock matches.
    var healthyProducts: [Product] {
        filteredProducts.filter { !$0.isLowStock }
    }

    /// Whether any filter is narrowing the list.
    var isFiltering: Bool { !searchText.trimmed.isEmpty || selectedBrand != nil }

    /// Total units held.
    var unitCount: Int { products.reduce(0) { $0 + $1.stockQuantity } }

    /// What the shelf cost to buy.
    var stockValueAtCost: Money {
        Money(
            products.reduce(Decimal(0)) { $0 + $1.costPrice.amount * Decimal($1.stockQuantity) },
            currency
        )
    }

    /// What the shelf is worth at retail.
    var stockValueAtRetail: Money {
        Money(
            products.reduce(Decimal(0)) { $0 + $1.retailPrice.amount * Decimal($1.stockQuantity) },
            currency
        )
    }

    /// Retail value minus cost — the margin sitting on the shelf.
    var potentialMargin: Money { stockValueAtRetail - stockValueAtCost }

    /// How many lines are at or under their reorder threshold.
    var lowStockCount: Int { products.count(where: \.isLowStock) }

    /// How many lines expire inside the warning window.
    var expiringCount: Int {
        products.count { product in
            guard let days = daysUntilExpiry(product) else { return false }
            return days <= InventoryRules.expiryWarningDays
        }
    }

    /// Orders still to arrive, newest first.
    var openOrders: [PurchaseOrder] {
        purchaseOrders
            .filter { $0.status == .draft || $0.status == .sent }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Closed orders (received or cancelled), newest first.
    var closedOrders: [PurchaseOrder] {
        purchaseOrders
            .filter { $0.status == .received || $0.status == .cancelled }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Days until a product expires, or `nil` when it never does.
    func daysUntilExpiry(_ product: Product) -> Int? {
        guard let expiresAt = product.expiresAt else { return nil }
        return calendar.dateComponents(
            [.day],
            from: Date.now.startOfDay(in: calendar),
            to: expiresAt.startOfDay(in: calendar)
        ).day
    }

    /// Supplier name for an order, falling back to a neutral label.
    func supplierName(_ id: Supplier.ID) -> String {
        suppliers.first { $0.id == id }?.name ?? "Supplier"
    }

    /// The quantity to show for a product — the optimistic value while a write
    /// is in flight, otherwise the stored one.
    func displayedStock(for product: Product) -> Int {
        pendingStock[product.id] ?? product.stockQuantity
    }

    /// Whether a write for this product is in flight.
    func isSaving(_ product: Product) -> Bool {
        savingProductIDs.contains(product.id)
    }

    // MARK: Loading

    /// Loads stock, suppliers, and purchase orders for the salon.
    func load(salonID: Salon.ID, using deps: PRVDependencies) async {
        if !hasLoadedOnce { phase = .loading }

        async let salonTask = deps.salons.salon(id: salonID)
        async let productsTask = deps.inventory.products(salonID: salonID)
        async let suppliersTask = deps.inventory.suppliers()
        async let ordersTask = deps.inventory.purchaseOrders(salonID: salonID)

        salon = try? await salonTask
        suppliers = (try? await suppliersTask) ?? []

        do {
            products = try await productsTask
            pendingStock.removeAll()
            phase = .loaded
        } catch {
            phase = .failed(OperationsCopy.loadMessage(for: error, subject: "your stock"))
        }

        do {
            purchaseOrders = try await ordersTask
            ordersError = nil
        } catch {
            purchaseOrders = []
            ordersError = OperationsCopy.loadMessage(for: error, subject: "purchase orders")
        }

        hasLoadedOnce = true
    }

    // MARK: Filters

    /// Toggles a brand chip, clearing it when tapped again.
    func toggleBrand(_ brand: String) {
        selectedBrand = selectedBrand == brand ? nil : brand
    }

    /// Clears the search text and brand chip.
    func clearFilters() {
        searchText = ""
        selectedBrand = nil
    }

    // MARK: Stock adjustment

    /// Moves a product's stock, writing through after a short pause.
    ///
    /// The stepper is a high-frequency control; debouncing keeps a burst of
    /// taps to one `upsertProduct` while the number on screen stays live.
    func adjustStock(of product: Product, to newValue: Int, using deps: PRVDependencies) {
        let clamped = max(0, newValue)
        guard clamped != displayedStock(for: product) else { return }
        pendingStock[product.id] = clamped

        stockWrites[product.id]?.cancel()
        stockWrites[product.id] = Task { [weak self] in
            try? await Task.sleep(for: InventoryRules.stockWriteDelay)
            guard !Task.isCancelled else { return }
            await self?.commitStock(for: product.id, using: deps)
        }
    }

    private func commitStock(for productID: Product.ID, using deps: PRVDependencies) async {
        guard
            let target = pendingStock[productID],
            let index = products.firstIndex(where: { $0.id == productID })
        else { return }

        guard products[index].stockQuantity != target else {
            pendingStock[productID] = nil
            return
        }

        var updated = products[index]
        updated.stockQuantity = target

        savingProductIDs.insert(productID)
        defer { savingProductIDs.remove(productID) }

        do {
            let saved = try await deps.inventory.upsertProduct(updated)
            apply(saved)
            pendingStock[productID] = nil
            if saved.isLowStock {
                toast = .warning("\(saved.name) is at \(saved.stockQuantity) — time to reorder")
            }
        } catch {
            pendingStock[productID] = nil
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "update this product"))
        }
    }

    private func apply(_ product: Product) {
        if let index = products.firstIndex(where: { $0.id == product.id }) {
            products[index] = product
        } else {
            products.append(product)
        }
        if barcodeResult?.id == product.id {
            barcodeResult = product
        }
    }

    // MARK: Barcode

    /// Looks a barcode up against the salon's catalogue.
    func lookUpBarcode(salonID: Salon.ID, using deps: PRVDependencies) async {
        let code = barcodeQuery.trimmed
        guard !code.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        defer { isLookingUp = false }

        do {
            let product = try await deps.inventory.product(barcode: code, salonID: salonID)
            apply(product)
            barcodeResult = product
            PRVHaptics.success()
        } catch {
            barcodeResult = nil
            PRVHaptics.warning()
            toast = .warning("No product in this salon matches \(code).")
        }
    }

    /// Handles a scan from the VisionKit scanner: fill the field and look up.
    func handleScan(_ payload: String, salonID: Salon.ID, using deps: PRVDependencies) async {
        barcodeQuery = payload
        isPresentingScanner = false
        await lookUpBarcode(salonID: salonID, using: deps)
    }

    /// Clears the barcode result card.
    func clearBarcodeResult() {
        barcodeResult = nil
        barcodeQuery = ""
    }

    // MARK: Purchase orders

    /// Marks an order received and folds its lines back into stock.
    func receive(_ order: PurchaseOrder, using deps: PRVDependencies) async {
        guard order.status != .received, !receivingOrderIDs.contains(order.id) else { return }
        receivingOrderIDs.insert(order.id)
        defer { receivingOrderIDs.remove(order.id) }

        var updated = order
        updated.status = .received

        do {
            let saved = try await deps.inventory.upsertPurchaseOrder(updated)
            applyOrder(saved)

            var receivedUnits = 0
            for line in saved.lines {
                guard var product = products.first(where: { $0.id == line.productID }) else { continue }
                product.stockQuantity += line.quantity
                if let stored = try? await deps.inventory.upsertProduct(product) {
                    apply(stored)
                    receivedUnits += line.quantity
                }
            }

            PRVHaptics.success()
            toast = .success("Received \(receivedUnits) units from \(supplierName(saved.supplierID))")
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "receive this order"))
        }
    }

    /// Sends a new purchase order.
    /// - Returns: `true` when the order was created.
    @discardableResult
    func createOrder(
        _ draft: PurchaseOrderDraft,
        salonID: Salon.ID,
        using deps: PRVDependencies
    ) async -> Bool {
        guard let order = draft.order(salonID: salonID), !isSavingOrder else { return false }
        isSavingOrder = true
        defer { isSavingOrder = false }

        do {
            let saved = try await deps.inventory.upsertPurchaseOrder(order)
            applyOrder(saved)
            tab = .orders
            PRVHaptics.success()
            toast = .success("Order sent to \(supplierName(saved.supplierID)) · \(saved.totalCost.formatted)")
            return true
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "send this order"))
            return false
        }
    }

    private func applyOrder(_ order: PurchaseOrder) {
        if let index = purchaseOrders.firstIndex(where: { $0.id == order.id }) {
            purchaseOrders[index] = order
        } else {
            purchaseOrders.append(order)
        }
    }
}

// MARK: - Purchase order display

extension PurchaseOrder.Status {
    /// Label shown on the status pill.
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .sent: "Sent"
        case .received: "Received"
        case .cancelled: "Cancelled"
        }
    }

    /// Pill tint.
    var tint: Color {
        switch self {
        case .draft: Color.prv.textSecondary
        case .sent: Color.prv.accent
        case .received: Color.prv.success
        case .cancelled: Color.prv.danger
        }
    }
}
