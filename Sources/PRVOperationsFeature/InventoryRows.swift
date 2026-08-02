import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Value tiles

/// The stock-value summary: what the shelf cost, what it's worth, and how many
/// lines need attention.
struct InventoryValueTiles: View {
    let atCost: Money
    let atRetail: Money
    let margin: Money
    let unitCount: Int
    let lowStockCount: Int
    let expiringCount: Int

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: PRVSpacing.sm)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: PRVSpacing.sm) {
            PRVStatTile(
                label: "Stock at cost",
                value: OperationsFormat.compactCurrency(atCost)
            )
            .accessibilityLabel("Stock at cost \(atCost.formatted), \(OperationsFormat.integer(unitCount)) units")

            PRVStatTile(
                label: "Retail value",
                value: OperationsFormat.compactCurrency(atRetail)
            )
            .accessibilityLabel("Retail value \(atRetail.formatted), margin \(margin.formatted)")

            PRVStatTile(
                label: "Needs attention",
                value: "\(lowStockCount)",
                trend: lowStockCount > 0 ? .down("\(expiringCount) expiring") : .flat
            )
            .accessibilityLabel(
                lowStockCount > 0
                    ? "\(lowStockCount) lines low on stock, \(expiringCount) expiring soon"
                    : "Every line is above its reorder point"
            )
        }
    }
}

// MARK: - Barcode lookup

/// The barcode desk: type a code or scan one, and the matching product opens
/// with its stepper ready.
struct BarcodeLookupCard: View {
    @Binding var code: String
    let isLookingUp: Bool
    let isScannerAvailable: Bool
    let result: Product?
    let canManage: Bool
    let stock: Int
    let isSaving: Bool
    let daysUntilExpiry: Int?
    let lookUp: () -> Void
    let scan: () -> Void
    let clear: () -> Void
    let setStock: (Int) -> Void

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.body)
                        .foregroundStyle(Color.prv.accent)
                        .accessibilityHidden(true)
                    Text("Barcode lookup")
                        .prvStyle(.headline)
                    Spacer(minLength: 0)
                }

                HStack(spacing: PRVSpacing.xs) {
                    PRVSearchField(text: $code, prompt: "Barcode number", onSubmit: lookUp)

                    Button {
                        PRVHaptics.tap()
                        scan()
                    } label: {
                        Label("Scan", systemImage: "camera.viewfinder")
                            .font(.footnote.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.prvGlass)
                    .accessibilityLabel("Scan a barcode with the camera")
                    .accessibilityHint(
                        isScannerAvailable
                            ? "Opens the live scanner"
                            : "Live scanning is unavailable on this device"
                    )
                }

                HStack(spacing: PRVSpacing.xs) {
                    Button {
                        PRVHaptics.tap()
                        lookUp()
                    } label: {
                        if isLookingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Look Up")
                        }
                    }
                    .buttonStyle(.prvPrimary)
                    .disabled(code.trimmed.isEmpty || isLookingUp)
                    .accessibilityLabel("Look up this barcode")

                    if result != nil {
                        Button("Clear") {
                            PRVHaptics.tap()
                            clear()
                        }
                        .buttonStyle(.prvGlass)
                        .accessibilityLabel("Clear the lookup result")
                    }
                }

                if let result {
                    Divider().overlay(Color.prv.separator.opacity(0.5))
                    ProductRow(
                        product: result,
                        stock: stock,
                        isSaving: isSaving,
                        daysUntilExpiry: daysUntilExpiry,
                        canManage: canManage,
                        setStock: setStock
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: result?.id)
    }
}

// MARK: - Product row

/// One product on the shelf: photo, name, price, stock stepper, and the badges
/// that make a problem obvious at a glance.
struct ProductRow: View {
    let product: Product
    /// The quantity to display — optimistic while a write is in flight.
    let stock: Int
    let isSaving: Bool
    /// Days until expiry, or `nil` when the product never expires.
    let daysUntilExpiry: Int?
    /// Whether the session holds `.manageInventory`.
    let canManage: Bool
    let setStock: (Int) -> Void

    private var isLow: Bool { stock <= product.lowStockThreshold }
    private var isExpired: Bool { (daysUntilExpiry ?? .max) < 0 }
    private var isExpiringSoon: Bool {
        guard let daysUntilExpiry else { return false }
        return daysUntilExpiry >= 0 && daysUntilExpiry <= InventoryRules.expiryWarningDays
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                thumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(2)

                    Text(product.brand)
                        .prvStyle(.subheadline)
                        .lineLimit(1)

                    PRVPriceLabel(product.retailPrice.formatted)
                        .padding(.top, 2)
                }

                Spacer(minLength: PRVSpacing.xs)

                VStack(alignment: .trailing, spacing: PRVSpacing.xxs) {
                    Text("\(stock)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(isLow ? Color.prv.warning : Color.prv.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("in stock")
                        .prvStyle(.caption)
                }
            }

            PRVFlowLayout(spacing: PRVSpacing.xxs) {
                if isLow {
                    PRVBadge("Low stock", tint: Color.prv.warning)
                }
                if isExpired {
                    PRVBadge("Expired", tint: Color.prv.danger)
                } else if isExpiringSoon, let daysUntilExpiry {
                    PRVBadge("Expires \(OperationsFormat.relativeDays(daysUntilExpiry))", tint: Color.prv.warning)
                }
                if !product.isRetail {
                    PRVTag("Back bar", systemImage: "drop")
                }
                PRVTag("Reorder at \(product.lowStockThreshold)", systemImage: "arrow.triangle.2.circlepath")
                PRVTag("Cost \(product.costPrice.formatted)", systemImage: "eurosign.circle")
            }

            if canManage {
                HStack(spacing: PRVSpacing.sm) {
                    PRVQuantityStepper(
                        value: stockBinding,
                        in: 0...999,
                        label: "Stock for \(product.name)"
                    )

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving stock level")
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, PRVSpacing.xxs)
        .prvAnimation(PRVMotion.quick, value: stock)
    }

    /// Writes every change straight back through the model, which debounces the
    /// network call.
    private var stockBinding: Binding<Int> {
        Binding(get: { stock }, set: { setStock($0) })
    }

    private var thumbnail: some View {
        Group {
            if product.imageURL != nil {
                PRVAsyncImage(url: product.imageURL)
            } else {
                ZStack {
                    Color.prv.surface
                    Image(systemName: "shippingbox.fill")
                        .font(.title3)
                        .foregroundStyle(Color.prv.accent.opacity(0.6))
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(PRVRadius.shape(PRVRadius.md))
        .accessibilityHidden(true)
    }
}

// MARK: - Low stock banner

/// The pinned header above the low-stock section.
struct LowStockBanner: View {
    let count: Int

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 line needs reordering" : "\(count) lines need reordering")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                Text("These are at or under their reorder point.")
                    .prvStyle(.caption)
            }

            Spacer(minLength: 0)
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.warning.opacity(0.12), in: PRVRadius.shape(PRVRadius.md))
        .overlay {
            PRVRadius.shape(PRVRadius.md)
                .strokeBorder(Color.prv.warning.opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Product rows") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            LowStockBanner(count: 2)

            ProductRow(
                product: Product(
                    salonID: PreviewData.salonLumiere.id,
                    name: "Élixir Ultime Oil",
                    brand: "Kérastase",
                    barcode: "3474636400584",
                    retailPrice: Money(48),
                    costPrice: Money(26),
                    stockQuantity: 3,
                    expiresAt: Date.now.addingTimeInterval(86_400 * 24)
                ),
                stock: 3,
                isSaving: false,
                daysUntilExpiry: 24,
                canManage: true,
                setStock: { _ in }
            )
            .prvGlassCard()

            ProductRow(
                product: Product(
                    salonID: PreviewData.salonLumiere.id,
                    name: "No.4 Bond Maintenance Shampoo",
                    brand: "Olaplex",
                    retailPrice: Money(32),
                    costPrice: Money(17),
                    stockQuantity: 24
                ),
                stock: 24,
                isSaving: true,
                daysUntilExpiry: nil,
                canManage: true,
                setStock: { _ in }
            )
            .prvGlassCard()
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}
