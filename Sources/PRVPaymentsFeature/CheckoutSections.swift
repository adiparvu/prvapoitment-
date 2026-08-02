import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVPaymentsKit

// MARK: - Summary row

/// One label-and-amount row inside a checkout card.
struct CheckoutSummaryRow: View {
    let label: String
    let value: String
    var systemImage: String?
    var tint: Color = .prv.textSecondary
    var isProminent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(isProminent ? .headline : .subheadline)
                .foregroundStyle(isProminent ? Color.prv.textPrimary : tint)
            Spacer(minLength: PRVSpacing.xs)
            Text(value)
                .font(isProminent ? .headline : .subheadline.weight(.medium))
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

// MARK: - Line items

/// The itemized order: every line the salon charged for, the reductions that
/// applied, the tip being added now, and the VAT contained in the total.
struct CheckoutLineItemsCard: View {
    let order: Order
    let vat: VATBreakdown
    let tip: Money
    let dueToday: Money
    /// Gift-card balance consumed by this payment.
    var giftCardCredit: Money = .zero()
    /// Store credit consumed by this payment.
    var storeCredit: Money = .zero()
    /// What the chosen payment method is actually charged.
    let chargedNow: Money
    /// What is left for the salon on the day.
    let remaining: Money

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                ForEach(order.lines) { line in
                    CheckoutSummaryRow(
                        label: "\(PaymentsFormatting.quantityPrefix(line.quantity))\(line.title)",
                        value: line.total.formatted,
                        systemImage: symbol(for: line.kind)
                    )
                }

                if !order.discount.isZero {
                    CheckoutSummaryRow(
                        label: order.discountReason ?? "Discount",
                        value: "−\(order.discount.formatted)",
                        systemImage: "tag.fill",
                        tint: Color.prv.success
                    )
                }

                if !tip.isZero {
                    CheckoutSummaryRow(
                        label: "Tip",
                        value: tip.formatted,
                        systemImage: "heart.fill",
                        tint: Color.prv.accent
                    )
                }

                if !order.amountPaid.isZero {
                    CheckoutSummaryRow(
                        label: "Already paid",
                        value: "−\(order.amountPaid.formatted)",
                        systemImage: "checkmark.circle.fill",
                        tint: Color.prv.success
                    )
                }

                Divider()

                CheckoutSummaryRow(
                    label: "Due today",
                    value: dueToday.formatted,
                    isProminent: !hasCredits
                )

                if !giftCardCredit.isZero {
                    CheckoutSummaryRow(
                        label: "Gift card",
                        value: "−\(giftCardCredit.formatted)",
                        systemImage: "giftcard.fill",
                        tint: Color.prv.gold
                    )
                }

                if !storeCredit.isZero {
                    CheckoutSummaryRow(
                        label: "Store credit",
                        value: "−\(storeCredit.formatted)",
                        systemImage: "wallet.pass.fill",
                        tint: Color.prv.success
                    )
                }

                if hasCredits {
                    CheckoutSummaryRow(
                        label: "Charged now",
                        value: chargedNow.formatted,
                        isProminent: true
                    )
                }

                if !remaining.isZero {
                    CheckoutSummaryRow(
                        label: "At the salon",
                        value: remaining.formatted,
                        systemImage: "banknote.fill"
                    )
                }

                Text(vat.receiptNote)
                    .prvStyle(.caption)
                    .padding(.top, PRVSpacing.xxs)
                    .accessibilityLabel("Prices include \(vat.vat.formatted) of VAT")
            }
        }
    }

    /// Whether any balance is being spent before the card is charged.
    private var hasCredits: Bool { !giftCardCredit.isZero || !storeCredit.isZero }

    /// SF Symbol for an order line's kind.
    private func symbol(for kind: OrderLine.Kind) -> String {
        switch kind {
        case .service: "sparkles"
        case .product: "shippingbox.fill"
        case .membership: "crown.fill"
        case .package: "gift.fill"
        case .giftCard: "giftcard.fill"
        case .tip: "heart.fill"
        case .fee: "info.circle.fill"
        }
    }
}

// MARK: - Tip selector

/// Tip chips that recompute the total as they are tapped, with an inline
/// field for a custom amount.
struct CheckoutTipSelector: View {
    @Bindable var model: CheckoutModel
    @FocusState private var isCustomFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Add a tip", subtitle: "100% goes to your artist")

            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(TipChoice.options) { choice in
                    PRVChip(
                        chipTitle(choice),
                        isSelected: model.tipChoice == choice
                    ) {
                        model.tipChoice = choice
                        if choice == .custom {
                            isCustomFocused = true
                        } else {
                            isCustomFocused = false
                            model.customTipText = ""
                        }
                    }
                }
            }

            if model.tipChoice == .custom {
                HStack(spacing: PRVSpacing.xs) {
                    Text(model.currency.symbol)
                        .prvStyle(.headline)
                        .accessibilityHidden(true)
                    TextField("0.00", text: $model.customTipText)
                        .keyboardType(.decimalPad)
                        .submitLabel(.done)
                        .focused($isCustomFocused)
                        .monospacedDigit()
                        .padding(PRVSpacing.sm)
                        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                        .accessibilityLabel("Custom tip amount")
                }
                .transition(.opacity.combined(with: .offset(y: -PRVSpacing.xs)))
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.tipChoice)
    }

    /// Percentage chips show what they cost, so the choice is never abstract.
    private func chipTitle(_ choice: TipChoice) -> String {
        guard case .percent(let percent) = choice else { return choice.title }
        let amount = Tip.percent(Decimal(percent)).resolved(on: model.outstandingBalance)
        return "\(percent)% · \(amount.formatted)"
    }
}

// MARK: - Partial payment

/// The deposit control for orders tied to an upcoming visit: settle
/// everything, or pay the salon's minimum deposit and clear the balance on
/// the day.
struct CheckoutPartialPaymentControl: View {
    @Bindable var model: CheckoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("How much today")

            PRVSegmentedGlassControl(
                selection: $model.amountChoice,
                options: CheckoutAmountChoice.allCases,
                title: \.title
            )

            PRVGlassCard {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    ForEach(model.depositSchedule.installments) { installment in
                        CheckoutSummaryRow(
                            label: installment.label,
                            value: installment.amount.formatted,
                            systemImage: installment.kind == .deposit ? "creditcard.fill" : "banknote.fill",
                            isProminent: isActive(installment)
                        )
                    }
                    Text(model.amountChoice == .deposit
                         ? "Your slot is held the moment the deposit clears."
                         : "Settle everything now and walk out without a bill.")
                        .prvStyle(.caption)
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.amountChoice)
    }

    /// Highlights the line the current choice actually charges today.
    private func isActive(_ installment: PaymentInstallment) -> Bool {
        model.amountChoice == .deposit ? installment.kind == .deposit : installment.kind == .balance
    }
}

// MARK: - Payment methods

/// The ways to pay: a dedicated Apple Pay row, the client's vaulted methods,
/// and the two balances they can spend before reaching for a card.
struct CheckoutPaymentMethodList: View {
    @Bindable var model: CheckoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Payment method")

            if model.paymentOptions.isEmpty {
                PRVEmptyState(
                    systemImage: "creditcard",
                    title: "No payment method",
                    message: "Add a card to pay in the app, or settle at the salon."
                )
                .prvGlassCard(radius: PRVRadius.xl)
            } else {
                VStack(spacing: PRVSpacing.xs) {
                    ForEach(model.paymentOptions) { option in
                        methodRow(option)
                    }
                }
            }

            creditRows
        }
    }

    // MARK: Rows

    private func methodRow(_ option: CheckoutPaymentOption) -> some View {
        let isSelected = model.selectedOption == option
        return Button {
            PRVHaptics.tap()
            model.selectedOption = option
        } label: {
            PRVListRow(title: option.title, subtitle: option.subtitle) {
                PRVListRowIcon(
                    systemImage: option.symbolName,
                    tint: option == .applePay ? Color.prv.textPrimary : Color.prv.accent
                )
            } trailing: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.prv.accent : Color.prv.separator)
                    .accessibilityHidden(true)
            }
            .padding(PRVSpacing.sm)
            .background {
                PRVRadius.shape(PRVRadius.md)
                    .fill(isSelected ? Color.prv.accent.opacity(0.10) : Color.clear)
            }
            .overlay {
                PRVRadius.shape(PRVRadius.md)
                    .strokeBorder(
                        isSelected ? Color.prv.accent.opacity(0.35) : Color.prv.separator.opacity(0.4),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .prvAnimation(PRVMotion.quick, value: isSelected)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var creditRows: some View {
        VStack(spacing: PRVSpacing.xs) {
            giftCardRow
            storeCreditRow
        }
        .padding(.top, PRVSpacing.xxs)
    }

    @ViewBuilder
    private var giftCardRow: some View {
        if let card = model.appliedGiftCard {
            PRVListRow(
                title: "Gift card \(card.code)",
                subtitle: "\(model.giftCardCredit.formatted) applied to this payment"
            ) {
                PRVListRowIcon(systemImage: "giftcard.fill", tint: Color.prv.gold)
            } trailing: {
                Button("Remove") { model.removeGiftCard() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove gift card \(card.code)")
            }
            .padding(PRVSpacing.sm)
            .background(Color.prv.gold.opacity(0.10), in: PRVRadius.shape(PRVRadius.md))
        } else {
            Button {
                PRVHaptics.tap()
                model.isRedeemingGiftCard = true
            } label: {
                PRVListRow(
                    title: "Redeem a gift card",
                    subtitle: "Apply a balance before paying",
                    systemImage: "giftcard.fill",
                    tint: Color.prv.gold
                )
                .padding(PRVSpacing.sm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Redeem a gift card")
        }
    }

    private var storeCreditRow: some View {
        let hasCredit = model.storeCreditBalance.amount > 0
        return Button {
            model.toggleStoreCredit()
        } label: {
            PRVListRow(
                title: "Store credit",
                subtitle: hasCredit
                    ? "\(model.storeCreditBalance.formatted) available"
                    : "No credit yet — cashback lands here"
            ) {
                PRVListRowIcon(systemImage: "wallet.pass.fill", tint: Color.prv.success)
            } trailing: {
                Image(systemName: model.usesStoreCredit ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(model.usesStoreCredit ? Color.prv.success : Color.prv.separator)
                    .accessibilityHidden(true)
            }
            .padding(PRVSpacing.sm)
        }
        .buttonStyle(.plain)
        .disabled(!hasCredit)
        .opacity(hasCredit ? 1 : 0.55)
        .prvAnimation(PRVMotion.quick, value: model.usesStoreCredit)
        .accessibilityLabel("Store credit")
        .accessibilityValue(model.usesStoreCredit ? "Applied" : "Not applied")
        .accessibilityAddTraits(model.usesStoreCredit ? [.isButton, .isSelected] : .isButton)
    }
}
