import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Order card

/// One purchase order: supplier, status, lines, total, and — while it's still
/// open — the action that receives it into stock.
struct PurchaseOrderCard: View {
    let order: PurchaseOrder
    let supplierName: String
    /// Whether the session holds `.manageInventory`.
    let canManage: Bool
    let isReceiving: Bool
    let receive: () -> Void

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                header
                lines
                Divider().overlay(Color.prv.separator.opacity(0.5))
                footer
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(supplierName)
                    .prvStyle(.headline)
                    .lineLimit(1)
                Text("Placed \(OperationsFormat.date(order.createdAt))")
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            OperationsStatusPill(title: order.status.displayName, tint: order.status.tint)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var lines: some View {
        if order.lines.isEmpty {
            Text("No lines on this order.")
                .prvStyle(.caption)
        } else {
            VStack(spacing: PRVSpacing.xs) {
                ForEach(Array(order.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                        Text("\(line.quantity)×")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.prv.accent)
                            .monospacedDigit()

                        Text(line.productName)
                            .prvStyle(.subheadline)
                            .lineLimit(1)

                        Spacer(minLength: PRVSpacing.xs)

                        Text((line.unitCost * Decimal(line.quantity)).formatted)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(line.quantity) × \(line.productName), \((line.unitCost * Decimal(line.quantity)).formatted)"
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.totalCost.formatted)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
                if let expectedAt = order.expectedAt {
                    Text("Expected \(OperationsFormat.date(expectedAt))")
                        .prvStyle(.caption)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: PRVSpacing.xs)

            if canManage && (order.status == .draft || order.status == .sent) {
                Button {
                    PRVHaptics.impact()
                    receive()
                } label: {
                    if isReceiving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Receive", systemImage: "tray.and.arrow.down.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .buttonStyle(.prvGlass)
                .disabled(isReceiving)
                .accessibilityLabel("Receive this order into stock")
                .accessibilityHint("Marks the order received and adds every line to stock")
            }
        }
    }
}

// MARK: - New order sheet

/// Builds a purchase order: pick a supplier, add lines from the catalogue, and
/// send it. Line costs default to each product's stored cost price and stay
/// editable for a supplier's current pricing.
struct NewPurchaseOrderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let suppliers: [Supplier]
    let products: [Product]
    let currency: Currency
    let isSaving: Bool
    /// Persists the order. Returns `true` when the sheet should close.
    let send: @MainActor (PurchaseOrderDraft) async -> Bool

    @State private var draft = PurchaseOrderDraft()
    @State private var selectedProductID: Product.ID?
    @State private var quantity = 1
    @State private var unitCost: Decimal = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    supplierCard
                    lineBuilder
                    linesCard
                }
                .padding(PRVSpacing.md)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("New Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .prvBottomBar {
                HStack(spacing: PRVSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.total.formatted)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .monospacedDigit()
                        Text("\(draft.unitCount) units")
                            .prvStyle(.caption)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Order total \(draft.total.formatted), \(draft.unitCount) units")

                    Spacer(minLength: PRVSpacing.xs)

                    Button {
                        submit()
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Send Order")
                        }
                    }
                    .buttonStyle(.prvPrimary)
                    .frame(maxWidth: 180)
                    .disabled(!draft.isValid || isSaving)
                    .accessibilityLabel("Send this order to the supplier")
                }
            }
            .onAppear(perform: primeSelection)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Supplier

    private var supplierCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                if suppliers.isEmpty {
                    Text("No suppliers are set up for this salon yet. Add one before placing an order.")
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Supplier", selection: $draft.supplierID) {
                        Text("Choose a supplier").tag(Supplier.ID?.none)
                        ForEach(suppliers) { supplier in
                            Text(supplier.name).tag(Supplier.ID?.some(supplier.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.prv.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Supplier for this order")
                }

                Divider()

                DatePicker(
                    "Expected",
                    selection: $draft.expectedAt,
                    in: Date.now...,
                    displayedComponents: [.date]
                )
                .tint(Color.prv.accent)
                .accessibilityLabel("Expected delivery date")
            }
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: Line builder

    private var lineBuilder: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Add a line", subtitle: "Pick a product, quantity, and unit cost")

            PRVGlassCard {
                VStack(alignment: .leading, spacing: PRVSpacing.md) {
                    if products.isEmpty {
                        Text("This salon has no products yet, so there's nothing to order.")
                            .prvStyle(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Product", selection: $selectedProductID) {
                            Text("Choose a product").tag(Product.ID?.none)
                            ForEach(products) { product in
                                Text("\(product.brand) · \(product.name)").tag(Product.ID?.some(product.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.prv.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Product to add to the order")

                        Divider()

                        HStack(spacing: PRVSpacing.md) {
                            Text("Quantity")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            PRVQuantityStepper(value: $quantity, in: 1...999, label: "Order quantity")
                        }

                        HStack(spacing: PRVSpacing.md) {
                            Text("Unit cost")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            TextField(
                                "0",
                                value: $unitCost,
                                format: Decimal.FormatStyle.Currency(code: currency.rawValue)
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .frame(maxWidth: 140)
                            .accessibilityLabel("Unit cost")
                        }

                        Button {
                            addLine()
                        } label: {
                            Label("Add Line", systemImage: "plus.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.prvGlass)
                        .disabled(selectedProductID == nil)
                        .accessibilityLabel("Add this line to the order")
                    }
                }
            }
        }
        .onChange(of: selectedProductID) { _, newValue in
            // A freshly picked product brings its own cost price along.
            guard let newValue, let product = products.first(where: { $0.id == newValue }) else { return }
            unitCost = product.costPrice.amount
        }
    }

    // MARK: Lines

    private var linesCard: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Order lines", subtitle: draft.lines.isEmpty ? "Nothing added yet" : nil)

            if draft.lines.isEmpty {
                Text("Lines you add appear here with a running total.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .prvGlassCard()
            } else {
                VStack(spacing: PRVSpacing.xs) {
                    ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
                        OperationsSwipeRow(
                            deleteLabel: "Remove \(line.productName)",
                            onDelete: { removeLine(at: index) }
                        ) {
                            HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                                Text("\(line.quantity)×")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.prv.accent)
                                    .monospacedDigit()
                                Text(line.productName)
                                    .prvStyle(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: PRVSpacing.xs)
                                Text((line.unitCost * Decimal(line.quantity)).formatted)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.prv.textPrimary)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "\(line.quantity) × \(line.productName), \((line.unitCost * Decimal(line.quantity)).formatted)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// Preselects the first supplier and product so the sheet opens ready to
    /// build rather than ready to configure.
    private func primeSelection() {
        if draft.supplierID == nil { draft.supplierID = suppliers.first?.id }
        if selectedProductID == nil, let first = products.first {
            selectedProductID = first.id
            unitCost = first.costPrice.amount
        }
    }

    private func addLine() {
        guard
            let selectedProductID,
            let product = products.first(where: { $0.id == selectedProductID })
        else { return }

        PRVHaptics.impact()
        let cost = Money(max(0, unitCost), currency)
        if let index = draft.lines.firstIndex(where: { $0.productID == product.id && $0.unitCost == cost }) {
            draft.lines[index].quantity += quantity
        } else {
            draft.lines.append(
                PurchaseOrder.Line(
                    productID: product.id,
                    productName: "\(product.brand) \(product.name)",
                    quantity: quantity,
                    unitCost: cost
                )
            )
        }
        quantity = 1
    }

    private func removeLine(at index: Int) {
        guard draft.lines.indices.contains(index) else { return }
        draft.lines.remove(at: index)
    }

    private func submit() {
        guard draft.isValid, !isSaving else { return }
        PRVHaptics.impact()
        Task {
            if await send(draft) { dismiss() }
        }
    }
}

// MARK: - Previews

#Preview("Purchase order") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            PurchaseOrderCard(
                order: PurchaseOrder(
                    salonID: PreviewData.salonLumiere.id,
                    supplierID: Supplier.ID(),
                    lines: [
                        PurchaseOrder.Line(
                            productID: Product.ID(),
                            productName: "Olaplex No.4 Shampoo",
                            quantity: 12,
                            unitCost: Money(17)
                        ),
                        PurchaseOrder.Line(
                            productID: Product.ID(),
                            productName: "Kérastase Élixir Ultime",
                            quantity: 6,
                            unitCost: Money(26)
                        ),
                    ],
                    status: .sent,
                    expectedAt: Date.now.addingTimeInterval(86_400 * 5)
                ),
                supplierName: "Beauty Supplies BV",
                canManage: true,
                isReceiving: false,
                receive: {}
            )
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}
