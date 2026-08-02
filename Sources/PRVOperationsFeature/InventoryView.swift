import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The Inventory desk: everything on the shelf and everything on its way.
///
/// **Stock** pins low-stock lines above the rest, filters by brand and free
/// text, adjusts quantities with a debounced stepper, flags anything expiring
/// inside 60 days, and looks products up by barcode — typed, or scanned with
/// VisionKit where the device supports it.
///
/// **Orders** lists purchase orders with their status, receives them into stock
/// in one tap, and builds new ones from the salon's supplier list.
///
/// Presented on its own, or embedded in ``TeamView``'s operations hub.
public struct InventoryView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    @State private var model = InventoryModel()

    /// `true` when hosted inside ``TeamView``, which owns the navigation title.
    private let isEmbedded: Bool

    /// Creates the inventory desk. All dependencies come from the environment;
    /// the initializer stays empty by contract.
    public init() {
        self.isEmbedded = false
    }

    /// Creates the desk for embedding inside the operations hub.
    init(isEmbedded: Bool) {
        self.isEmbedded = isEmbedded
    }

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                PRVSegmentedGlassControl(
                    selection: $model.tab,
                    options: InventoryTab.allCases,
                    title: \.title
                )
                .accessibilityLabel("Inventory view")

                switch model.phase {
                case .loading:
                    OperationsSkeleton(rows: 4, label: "Loading your stock")
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    switch model.tab {
                    case .stock: stockTab
                    case .orders: ordersTab
                    }
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, isEmbedded ? 0 : PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.prv.canvas)
        .operationsNavigationTitle("Inventory", isEmbedded: isEmbedded)
        .refreshable { await load() }
        .task(id: salonID.description) { await load() }
        .prvToast($model.toast)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .prvAnimation(PRVMotion.morph, value: model.tab)
        .sheet(isPresented: $model.isPresentingScanner) {
            BarcodeScannerSheet { payload in
                Task { await model.handleScan(payload, salonID: salonID, using: deps) }
            }
        }
        .sheet(isPresented: $model.isPresentingNewOrder) {
            NewPurchaseOrderSheet(
                suppliers: model.suppliers,
                products: model.products,
                currency: model.currency,
                isSaving: model.isSavingOrder,
                send: { draft in
                    await model.createOrder(draft, salonID: salonID, using: deps)
                }
            )
        }
    }

    // MARK: - Stock

    @ViewBuilder
    private var stockTab: some View {
        @Bindable var model = model

        InventoryValueTiles(
            atCost: model.stockValueAtCost,
            atRetail: model.stockValueAtRetail,
            margin: model.potentialMargin,
            unitCount: model.unitCount,
            lowStockCount: model.lowStockCount,
            expiringCount: model.expiringCount
        )

        BarcodeLookupCard(
            code: $model.barcodeQuery,
            isLookingUp: model.isLookingUp,
            isScannerAvailable: BarcodeScanner.isAvailable,
            result: model.barcodeResult,
            canManage: canManage,
            stock: model.barcodeResult.map { model.displayedStock(for: $0) } ?? 0,
            isSaving: model.barcodeResult.map { model.isSaving($0) } ?? false,
            daysUntilExpiry: model.barcodeResult.flatMap { model.daysUntilExpiry($0) },
            lookUp: { lookUpBarcode() },
            scan: { model.isPresentingScanner = true },
            clear: { model.clearBarcodeResult() },
            setStock: { newValue in
                guard let product = model.barcodeResult else { return }
                model.adjustStock(of: product, to: newValue, using: deps)
            }
        )

        filters

        if model.products.isEmpty {
            PRVEmptyState(
                systemImage: "shippingbox",
                title: "No products yet",
                message: "Add retail and back-bar products to track stock, value, and reorder points here.",
                actionTitle: "Refresh"
            ) {
                reload()
            }
        } else if model.filteredProducts.isEmpty {
            PRVEmptyState(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "Nothing matches",
                message: "No products match that search or brand. Try clearing the filters.",
                actionTitle: "Clear Filters"
            ) {
                model.clearFilters()
            }
        } else {
            if !model.lowStockProducts.isEmpty {
                OperationsBlock("Reorder First", subtitle: "Pinned above the rest of the shelf") {
                    VStack(spacing: PRVSpacing.sm) {
                        LowStockBanner(count: model.lowStockProducts.count)
                        ForEach(model.lowStockProducts) { product in
                            productRow(product)
                        }
                    }
                }
            }

            if !model.healthyProducts.isEmpty {
                OperationsBlock(
                    "Stock",
                    subtitle: "\(model.healthyProducts.count) lines above their reorder point"
                ) {
                    VStack(spacing: PRVSpacing.sm) {
                        ForEach(model.healthyProducts) { product in
                            productRow(product)
                        }
                    }
                }
            }
        }
    }

    private func productRow(_ product: Product) -> some View {
        ProductRow(
            product: product,
            stock: model.displayedStock(for: product),
            isSaving: model.isSaving(product),
            daysUntilExpiry: model.daysUntilExpiry(product),
            canManage: canManage,
            setStock: { newValue in
                model.adjustStock(of: product, to: newValue, using: deps)
            }
        )
        .prvGlassCard()
    }

    private var filters: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSearchField(text: $model.searchText, prompt: "Search products, brands, barcodes")

            if !model.brands.isEmpty {
                PRVFlowLayout(spacing: PRVSpacing.xs) {
                    PRVChip("All brands", isSelected: model.selectedBrand == nil) {
                        model.selectedBrand = nil
                    }
                    ForEach(model.brands, id: \.self) { brand in
                        PRVChip(brand, isSelected: model.selectedBrand == brand) {
                            model.toggleBrand(brand)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Orders

    @ViewBuilder
    private var ordersTab: some View {
        if canManage {
            Button {
                PRVHaptics.impact()
                model.isPresentingNewOrder = true
            } label: {
                Label("New Purchase Order", systemImage: "plus.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.prvPrimary)
            .accessibilityLabel("Create a new purchase order")
        } else {
            OperationsLockedNotice(
                title: "Ordering is restricted",
                message: "Purchase orders can only be created by team members with inventory permission."
            )
        }

        if let ordersError = model.ordersError {
            OperationsErrorCard(message: ordersError) { reload() }
        } else if model.purchaseOrders.isEmpty {
            PRVEmptyState(
                systemImage: "shippingbox.and.arrow.backward",
                title: "No orders yet",
                message: "Purchase orders you place show up here, ready to receive into stock when they arrive."
            )
        } else {
            if !model.openOrders.isEmpty {
                OperationsBlock("On Its Way", subtitle: "Receive an order to add its lines to stock") {
                    VStack(spacing: PRVSpacing.md) {
                        ForEach(model.openOrders) { order in
                            orderCard(order)
                        }
                    }
                }
            }

            if !model.closedOrders.isEmpty {
                OperationsBlock("History", subtitle: "Received and cancelled orders") {
                    VStack(spacing: PRVSpacing.md) {
                        ForEach(model.closedOrders) { order in
                            orderCard(order)
                        }
                    }
                }
            }
        }
    }

    private func orderCard(_ order: PurchaseOrder) -> some View {
        PurchaseOrderCard(
            order: order,
            supplierName: model.supplierName(order.supplierID),
            canManage: canManage,
            isReceiving: model.receivingOrderIDs.contains(order.id),
            receive: {
                Task { await model.receive(order, using: deps) }
            }
        )
    }

    // MARK: - States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "shippingbox.badge.clock",
            title: "Stock unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: - Actions

    /// The salon in scope, falling back to the flagship fixture so previews and
    /// demo mode always have stock to manage.
    private var salonID: Salon.ID {
        session.activeSalonID ?? PreviewData.salonLumiere.id
    }

    private var canManage: Bool { session.can(.manageInventory) }

    private func load() async {
        await model.load(salonID: salonID, using: deps)
    }

    private func reload() {
        PRVHaptics.tap()
        Task { await load() }
    }

    private func lookUpBarcode() {
        Task { await model.lookUpBarcode(salonID: salonID, using: deps) }
    }
}

// MARK: - Previews

#Preview("Inventory — Owner") {
    NavigationStack {
        InventoryView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .operations))
}

#Preview("Inventory — Dark") {
    NavigationStack {
        InventoryView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .operations))
    .preferredColorScheme(.dark)
}

#Preview("Inventory — Read only") {
    NavigationStack {
        InventoryView()
    }
    .environment(UserSession.previewSalonEmployee)
    .environment(AppRouter(selectedTab: .operations))
}
