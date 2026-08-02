import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Coupon row

/// One coupon: its code, what it takes off, how much of it has been used, and
/// a switch to pause it without deleting anything.
struct CouponRow: View {
    let coupon: Coupon
    /// Whether the session holds `.manageMarketing`.
    let canManage: Bool
    let isToggling: Bool
    let setActive: (Bool) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coupon.code)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                    Text(coupon.discountSummary)
                        .prvStyle(.subheadline)
                }

                Spacer(minLength: PRVSpacing.xs)

                if isToggling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating coupon")
                } else if canManage {
                    Toggle("Active", isOn: activeBinding)
                        .labelsHidden()
                        .tint(Color.prv.accent)
                        .accessibilityLabel("\(coupon.code) active")
                } else {
                    OperationsStatusPill(
                        title: coupon.isActive ? "Active" : "Paused",
                        tint: coupon.isActive ? Color.prv.success : Color.prv.textSecondary
                    )
                }
            }

            PRVFlowLayout(spacing: PRVSpacing.xxs) {
                if coupon.isExpired {
                    PRVBadge("Expired", tint: Color.prv.danger)
                } else if coupon.isExhausted {
                    PRVBadge("Fully redeemed", tint: Color.prv.warning)
                } else if !coupon.isActive {
                    PRVBadge("Paused", tint: Color.prv.textSecondary)
                }
                if let minimumSpend = coupon.minimumSpend {
                    PRVTag("Min spend \(minimumSpend.formatted)", systemImage: "cart")
                }
                if let validUntil = coupon.validUntil {
                    PRVTag("Until \(OperationsFormat.date(validUntil))", systemImage: "calendar")
                }
            }

            redemptions
        }
        .padding(.vertical, PRVSpacing.xxs)
        .contentShape(Rectangle())
        .onTapGesture {
            guard canManage else { return }
            edit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Edit coupon")) {
            guard canManage else { return }
            edit()
        }
    }

    private var activeBinding: Binding<Bool> {
        Binding(get: { coupon.isActive }, set: { setActive($0) })
    }

    @ViewBuilder
    private var redemptions: some View {
        if let fraction = coupon.redemptionFraction, let maxRedemptions = coupon.maxRedemptions {
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                HStack {
                    Text("Redeemed")
                        .prvStyle(.caption)
                    Spacer(minLength: PRVSpacing.xs)
                    Text("\(coupon.redemptionCount) / \(maxRedemptions)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .monospacedDigit()
                }
                OperationsMeter(
                    fraction: fraction,
                    tint: fraction >= 1
                        ? AnyShapeStyle(Color.prv.warning)
                        : AnyShapeStyle(Color.prv.accentGradient)
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Redeemed \(coupon.redemptionCount) of \(maxRedemptions)")
        } else {
            Text("\(coupon.redemptionCount) redeemed · no limit")
                .prvStyle(.caption)
        }
    }
}

// MARK: - Editor sheet

/// Creates or edits a coupon: a generated-or-typed code, a percentage or fixed
/// discount, and the limits that stop a promotion running away.
struct CouponEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let salonName: String
    let currency: Currency
    let isSaving: Bool
    /// Persists the draft. Returns `true` when the sheet should close.
    let save: @MainActor (CouponDraft) async -> Bool

    @State private var draft: CouponDraft

    init(
        draft: CouponDraft,
        salonName: String,
        currency: Currency,
        isSaving: Bool,
        save: @escaping @MainActor (CouponDraft) async -> Bool
    ) {
        self.salonName = salonName
        self.currency = currency
        self.isSaving = isSaving
        self.save = save
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    codeCard
                    discountCard
                    limitsCard
                }
                .padding(PRVSpacing.md)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(draft.isEditing ? "Edit Coupon" : "New Coupon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .prvBottomBar {
                Button {
                    submit()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(draft.isEditing ? "Save Coupon" : "Create Coupon")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(!draft.isValid || isSaving)
                .accessibilityLabel(draft.isEditing ? "Save this coupon" : "Create this coupon")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .prvAnimation(PRVMotion.spring, value: draft.isPercent)
    }

    // MARK: Code

    private var codeCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                Text("Code")
                    .prvStyle(.footnote)

                HStack(spacing: PRVSpacing.xs) {
                    TextField("GLOW-4F2A", text: $draft.code)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Coupon code")

                    Button {
                        PRVHaptics.tap()
                        draft.code = CouponDraft.generateCode(salonName: salonName)
                    } label: {
                        Label("Generate", systemImage: "dice")
                            .font(.footnote.weight(.semibold))
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.prvGlass)
                    .accessibilityLabel("Generate a new code")
                }

                Text("Clients type this at checkout, so keep it short and unambiguous.")
                    .prvStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                if !draft.code.isBlank && !draft.isValid {
                    OperationsFootnote(
                        "Codes need at least four characters and a discount above zero.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    // MARK: Discount

    private var discountCard: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Discount", subtitle: draft.discountSummary(currency: currency))

            PRVGlassCard {
                VStack(alignment: .leading, spacing: PRVSpacing.md) {
                    PRVSegmentedGlassControl(
                        selection: discountModeBinding,
                        options: ["Percent", "Fixed amount"]
                    )
                    .accessibilityLabel("Discount type")

                    Divider()

                    if draft.isPercent {
                        HStack(spacing: PRVSpacing.md) {
                            Text("Percent off")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            PRVQuantityStepper(value: $draft.percent, in: 1...100, label: "Percent off")
                        }
                    } else {
                        HStack(spacing: PRVSpacing.md) {
                            Text("Amount off")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            TextField(
                                "0",
                                value: $draft.fixedAmount,
                                format: Decimal.FormatStyle.Currency(code: currency.rawValue)
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .frame(maxWidth: 140)
                            .accessibilityLabel("Amount off")
                        }
                    }
                }
            }
        }
    }

    /// Bridges the segmented control's string options to the draft's flag.
    private var discountModeBinding: Binding<String> {
        Binding(
            get: { draft.isPercent ? "Percent" : "Fixed amount" },
            set: { draft.isPercent = $0 == "Percent" }
        )
    }

    // MARK: Limits

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Limits", subtitle: "Keep a promotion from running away")

            PRVGlassCard {
                VStack(alignment: .leading, spacing: PRVSpacing.md) {
                    Toggle("Cap redemptions", isOn: $draft.hasRedemptionLimit)
                        .font(.subheadline.weight(.medium))
                        .tint(Color.prv.accent)

                    if draft.hasRedemptionLimit {
                        HStack(spacing: PRVSpacing.md) {
                            Text("Maximum")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            PRVQuantityStepper(
                                value: $draft.maxRedemptions,
                                in: 1...9_999,
                                label: "Maximum redemptions"
                            )
                        }
                    }

                    Divider()

                    Toggle("Require a minimum spend", isOn: $draft.hasMinimumSpend)
                        .font(.subheadline.weight(.medium))
                        .tint(Color.prv.accent)

                    if draft.hasMinimumSpend {
                        HStack(spacing: PRVSpacing.md) {
                            Text("Minimum")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            TextField(
                                "0",
                                value: $draft.minimumSpend,
                                format: Decimal.FormatStyle.Currency(code: currency.rawValue)
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .frame(maxWidth: 140)
                            .accessibilityLabel("Minimum spend")
                        }
                    }

                    Divider()

                    Toggle("Set an end date", isOn: $draft.hasExpiry)
                        .font(.subheadline.weight(.medium))
                        .tint(Color.prv.accent)

                    if draft.hasExpiry {
                        DatePicker(
                            "Valid until",
                            selection: $draft.validUntil,
                            in: Date.now...,
                            displayedComponents: [.date]
                        )
                        .tint(Color.prv.accent)
                        .font(.subheadline.weight(.medium))
                        .accessibilityLabel("Valid until")
                    }

                    Divider()

                    Toggle("Active", isOn: $draft.isActive)
                        .font(.subheadline.weight(.medium))
                        .tint(Color.prv.accent)
                        .accessibilityHint("Paused coupons are rejected at checkout")
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: draft.hasRedemptionLimit)
        .prvAnimation(PRVMotion.spring, value: draft.hasMinimumSpend)
        .prvAnimation(PRVMotion.spring, value: draft.hasExpiry)
    }

    // MARK: Actions

    private func submit() {
        guard draft.isValid, !isSaving else { return }
        PRVHaptics.impact()
        Task {
            if await save(draft) { dismiss() }
        }
    }
}

// MARK: - Previews

#Preview("Coupons") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            CouponRow(
                coupon: Coupon(
                    salonID: PreviewData.salonLumiere.id,
                    code: "WELCOME10",
                    discount: .percent(10),
                    maxRedemptions: 200,
                    redemptionCount: 148,
                    minimumSpend: Money(60),
                    validUntil: Date.now.addingTimeInterval(86_400 * 40)
                ),
                canManage: true,
                isToggling: false,
                setActive: { _ in },
                edit: {}
            )
            .prvGlassCard()

            CouponRow(
                coupon: Coupon(
                    salonID: PreviewData.salonLumiere.id,
                    code: "GLOW-4F2A",
                    discount: .fixed(Money(15)),
                    isActive: false
                ),
                canManage: true,
                isToggling: false,
                setActive: { _ in },
                edit: {}
            )
            .prvGlassCard()
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}

#Preview("Coupon editor") {
    CouponEditorSheet(
        draft: CouponDraft(code: "MAIS-7K2Q"),
        salonName: PreviewData.salonLumiere.name,
        currency: .eur,
        isSaving: false,
        save: { _ in true }
    )
}
