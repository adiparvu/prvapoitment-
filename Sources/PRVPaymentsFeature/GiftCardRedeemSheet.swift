import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Redeems a gift card at checkout: the client types the code printed on the
/// card, and its remaining balance is applied to this payment before any card
/// is charged.
struct GiftCardRedeemSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(\.dismiss) private var dismiss

    @Bindable var model: CheckoutModel

    @State private var code = ""
    @State private var isRedeeming = false
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: PRVSpacing.lg) {
                header

                PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
                    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                        Text("Gift card code")
                            .prvStyle(.headline)

                        TextField("PRV-XXXX-XXXX", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isCodeFocused)
                            .onSubmit { Task { await redeem() } }
                            .padding(PRVSpacing.sm)
                            .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                            .accessibilityLabel("Gift card code")

                        Text("The balance is applied to this payment first; anything left stays on the card.")
                            .prvStyle(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(PRVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.prv.canvas)
            .navigationTitle("Redeem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel redemption")
                }
            }
            .prvBottomBar {
                Button {
                    Task { await redeem() }
                } label: {
                    if isRedeeming {
                        ProgressView().controlSize(.small).tint(Color.prv.textOnAccent)
                    } else {
                        Text("Apply gift card")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(code.trimmed.isBlank || isRedeeming)
                .accessibilityLabel("Apply gift card")
            }
            .onAppear { isCodeFocused = true }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: PRVSpacing.xs) {
            Image(systemName: "giftcard.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.prv.gold)
                .padding(PRVSpacing.md)
                .background(Color.prv.gold.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text("Use a gift card")
                .prvStyle(.title2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PRVSpacing.sm)
    }

    /// Redeems the typed code, closing the sheet on success.
    private func redeem() async {
        guard !code.trimmed.isBlank, !isRedeeming else { return }
        isCodeFocused = false
        isRedeeming = true
        defer { isRedeeming = false }
        await model.redeemGiftCard(code: code, using: deps)
        if model.appliedGiftCard != nil { dismiss() }
    }
}

#Preview("Redeem Gift Card") {
    GiftCardRedeemSheet(model: CheckoutModel(orderID: PaymentsPreview.openOrder.id))
        .environment(UserSession.previewClient)
}
