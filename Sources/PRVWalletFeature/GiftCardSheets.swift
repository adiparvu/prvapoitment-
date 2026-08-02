import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Buy

/// Buys a gift card: a preset amount (or a custom one), an optional recipient, and
/// an optional message. The purchase runs through `PaymentRepository`; the card
/// appears at the head of the wallet carousel on success.
struct BuyGiftCardSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let model: WalletModel

    @State private var selectedAmount = 50
    @State private var isCustom = false
    @State private var customAmount = 75
    @State private var recipientEmail = ""
    @State private var message = ""

    /// Preset amounts, in whole currency units.
    private let presets = [25, 50, 100, 150]

    private var amount: Money { Money(Decimal(isCustom ? customAmount : selectedAmount)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                    amountSection
                    recipientSection
                    summaryCard
                }
                .padding(PRVSpacing.lg)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Buy a Gift Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel gift card purchase")
                }
            }
            .prvBottomBar {
                Button {
                    buy()
                } label: {
                    if model.isWorking {
                        ProgressView()
                            .tint(Color.prv.textOnAccent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Buy \(amount.formatted)")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(model.isWorking || session.currentUser == nil)
                .accessibilityLabel("Buy a gift card for \(amount.formatted)")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Amount", subtitle: "Choose a value or set your own")

            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(presets, id: \.self) { preset in
                    PRVChip(
                        Money(Decimal(preset)).formatted,
                        isSelected: !isCustom && selectedAmount == preset
                    ) {
                        isCustom = false
                        selectedAmount = preset
                    }
                }
                PRVChip("Custom", systemImage: "slider.horizontal.3", isSelected: isCustom) {
                    isCustom = true
                }
            }

            if isCustom {
                HStack(spacing: PRVSpacing.md) {
                    Text("Custom amount")
                        .prvStyle(.subheadline)
                    Spacer()
                    PRVQuantityStepper(value: $customAmount, in: 5 ... 1_000, label: "Gift card amount")
                }
                .prvGlassCard()
                .transition(.opacity.combined(with: .offset(y: -PRVSpacing.xs)))
            }
        }
        .prvAnimation(PRVMotion.spring, value: isCustom)
    }

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Recipient", subtitle: "Leave empty to keep it for yourself")

            VStack(spacing: PRVSpacing.sm) {
                TextField("Email address", text: $recipientEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Recipient email address")

                Divider().overlay(Color.prv.separator)

                TextField("Message (optional)", text: $message, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .accessibilityLabel("Gift message")
            }
            .prvGlassCard()
        }
    }

    private var summaryCard: some View {
        HStack(spacing: PRVSpacing.md) {
            Image(systemName: "giftcard.fill")
                .font(.title2)
                .foregroundStyle(Color.prv.gold)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text("Valid for two years")
                    .prvStyle(.headline)
                Text("Redeemable at every PRV salon. The code is generated the moment the payment clears.")
                    .prvStyle(.footnote)
            }

            Spacer(minLength: 0)
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
    }

    // MARK: Actions

    private func buy() {
        guard let user = session.currentUser else { return }
        let purchaseAmount = amount
        let email = recipientEmail
        let note = message
        Task {
            let succeeded = await model.purchaseGiftCard(
                amount: purchaseAmount,
                recipientEmail: email,
                message: note,
                for: user,
                using: deps
            )
            if succeeded { dismiss() }
        }
    }
}

// MARK: - Redeem

/// Redeems a gift-card code into the wallet.
///
/// The field uppercases as you type and disables autocorrection, because the code
/// alphabet is deliberately unambiguous — see `ReferralEngine` for why.
struct RedeemGiftCardSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(\.dismiss) private var dismiss

    let model: WalletModel

    @State private var code = ""
    @FocusState private var isCodeFocused: Bool

    private var isSubmittable: Bool { code.trimmed.count >= 6 && !model.isWorking }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Enter your code")
                        .prvStyle(.title2)
                    Text("You'll find it in your gift card email or on the printed card.")
                        .prvStyle(.footnote)
                }

                TextField("GIFT-XXXX-XXXX", text: $code)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isCodeFocused)
                    .submitLabel(.go)
                    .onSubmit { redeem() }
                    .prvGlassCard()
                    .accessibilityLabel("Gift card code")

                Spacer(minLength: 0)
            }
            .padding(PRVSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.prv.canvas)
            .navigationTitle("Redeem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel redemption")
                }
            }
            .prvBottomBar {
                Button {
                    redeem()
                } label: {
                    if model.isWorking {
                        ProgressView()
                            .tint(Color.prv.textOnAccent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Add to Wallet")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(!isSubmittable)
                .accessibilityLabel("Add this gift card to your wallet")
            }
            .task { isCodeFocused = true }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func redeem() {
        guard isSubmittable else { return }
        let entered = code
        Task {
            let succeeded = await model.redeemGiftCard(code: entered, using: deps)
            if succeeded { dismiss() }
        }
    }
}

// MARK: - Previews

#Preview("Buy Gift Card") {
    BuyGiftCardSheet(model: WalletModel())
        .environment(UserSession.previewClient)
}

#Preview("Redeem Gift Card") {
    RedeemGiftCardSheet(model: WalletModel())
        .environment(UserSession.previewClient)
}
