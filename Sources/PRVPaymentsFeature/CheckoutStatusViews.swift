import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Processing

/// The full-screen scrim shown while a charge is in flight. It blocks every
/// control underneath — a payment must never be double-submitted — and names
/// the step in progress so the wait is never mysterious.
struct CheckoutProcessingOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let message: String
    let amount: Money

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: PRVSpacing.md) {
                ZStack {
                    Circle()
                        .stroke(Color.prv.accent.opacity(0.18), lineWidth: 4)
                        .frame(width: 84, height: 84)
                        .scaleEffect(isPulsing ? 1.08 : 0.94)
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.prv.accent)
                }
                .accessibilityHidden(true)

                VStack(spacing: PRVSpacing.xxs) {
                    Text(message)
                        .prvStyle(.headline)
                        .multilineTextAlignment(.center)
                    Text("Charging \(amount.formatted)")
                        .prvStyle(.subheadline)
                }
            }
            .padding(PRVSpacing.xl)
            .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
            .padding(PRVSpacing.xl)
        }
        .onAppear { isPulsing = !reduceMotion }
        .prvAnimation(
            PRVMotion.gentle.repeatForever(autoreverses: true),
            value: isPulsing
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message). Charging \(amount.formatted).")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var backdrop: some View {
        if reduceTransparency {
            Color.prv.canvas.opacity(0.96)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Success

/// The moment the payment lands: a seal that draws itself, the receipt, the
/// invoice the salon issued, and the cashback heading to the Beauty Wallet.
struct CheckoutSuccessView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let receipt: CheckoutReceipt
    let salonName: String
    /// Dismisses checkout — clears the router's presented sheet.
    let onDone: () -> Void

    @State private var isSealed = false

    var body: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.lg) {
                seal.padding(.top, PRVSpacing.lg)

                VStack(spacing: PRVSpacing.xs) {
                    Text("Payment complete")
                        .prvStyle(.largeTitle)
                        .multilineTextAlignment(.center)
                    Text("\(receipt.charged.formatted) paid to \(salonName).")
                        .prvStyle(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                receiptCard

                if !receipt.cashback.isZero {
                    cashbackCallout
                }

                Button("Done") {
                    PRVHaptics.tap()
                    onDone()
                }
                .buttonStyle(.prvPrimary)
                .padding(.top, PRVSpacing.xs)
                .accessibilityHint("Closes checkout")
            }
            .padding(.horizontal, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.prv.canvas)
        .onAppear { isSealed = true }
    }

    // MARK: Seal

    private var seal: some View {
        ZStack {
            Circle()
                .fill(Color.prv.success.opacity(0.10))

            Circle()
                .strokeBorder(Color.prv.gold.opacity(0.35), lineWidth: 1)
                .padding(-PRVSpacing.xs)
                .scaleEffect(isSealed ? 1 : 0.85)
                .opacity(isSealed ? 1 : 0)

            Circle()
                .trim(from: 0, to: isSealed ? 1 : 0)
                .stroke(
                    Color.prv.accentGradient,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(Color.prv.accentGradient)
                .scaleEffect(isSealed ? 1 : 0.3)
                .opacity(isSealed ? 1 : 0)
        }
        .frame(width: 132, height: 132)
        .prvAnimation(reduceMotion ? PRVMotion.quick : PRVMotion.gentle, value: isSealed)
        .accessibilityHidden(true)
    }

    // MARK: Receipt

    private var receiptCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                CheckoutSummaryRow(
                    label: "Paid",
                    value: receipt.charged.formatted,
                    isProminent: true
                )

                if let code = receipt.giftCardCode {
                    CheckoutSummaryRow(
                        label: "Gift card",
                        value: code,
                        systemImage: "giftcard.fill",
                        tint: Color.prv.gold
                    )
                }

                if !receipt.order.outstandingBalance.isZero {
                    CheckoutSummaryRow(
                        label: "Balance at the salon",
                        value: receipt.order.outstandingBalance.formatted,
                        systemImage: "banknote.fill"
                    )
                }

                if receipt.points > 0 {
                    CheckoutSummaryRow(
                        label: "Reward points",
                        value: "+\(receipt.points)",
                        systemImage: "sparkle",
                        tint: Color.prv.gold
                    )
                }

                Divider()

                if let invoice = receipt.invoice {
                    invoiceRow(invoice)
                } else {
                    CheckoutSummaryRow(
                        label: "Invoice",
                        value: "Arrives by email",
                        systemImage: "doc.text.fill"
                    )
                }
            }
        }
    }

    /// The invoice row — a share sheet when the salon attached a PDF, plain
    /// text otherwise.
    @ViewBuilder
    private func invoiceRow(_ invoice: Invoice) -> some View {
        if let url = invoice.pdfURL {
            ShareLink(item: url) {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "doc.text.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.prv.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invoice \(invoice.number)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                        Text(PaymentsFormatting.invoiceSubtitle(invoice))
                            .prvStyle(.caption)
                    }
                    Spacer(minLength: PRVSpacing.xs)
                    Image(systemName: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share invoice \(invoice.number)")
        } else {
            CheckoutSummaryRow(
                label: "Invoice",
                value: invoice.number,
                systemImage: "doc.text.fill"
            )
        }
    }

    // MARK: Cashback

    private var cashbackCallout: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: "wallet.pass.fill")
                .font(.title3)
                .foregroundStyle(Color.prv.success)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(receipt.cashback.formatted) cashback")
                    .font(.headline)
                    .foregroundStyle(Color.prv.textPrimary)
                Text("Credited to your Beauty Wallet, ready for your next visit.")
                    .prvStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(PRVSpacing.md)
        .background(Color.prv.success.opacity(0.10), in: PRVRadius.shape(PRVRadius.lg))
        .overlay {
            PRVRadius.shape(PRVRadius.lg)
                .strokeBorder(Color.prv.success.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(receipt.cashback.formatted) cashback credited to your Beauty Wallet")
    }
}

// MARK: - Previews

#Preview("Checkout Success — Light") {
    CheckoutSuccessView(
        receipt: CheckoutReceipt(
            order: PaymentsPreview.paidOrder,
            charged: Money(198),
            cashback: PaymentsPreview.money("3.96"),
            points: 396,
            invoice: Invoice(orderID: PaymentsPreview.paidOrder.id, number: "PRV-1001"),
            giftCardCode: nil
        ),
        salonName: PreviewData.salonLumiere.name,
        onDone: {}
    )
}

#Preview("Checkout Processing — Dark") {
    Color.prv.canvas
        .ignoresSafeArea()
        .overlay {
            CheckoutProcessingOverlay(message: "Securing your payment…", amount: Money(198))
        }
        .preferredColorScheme(.dark)
}
