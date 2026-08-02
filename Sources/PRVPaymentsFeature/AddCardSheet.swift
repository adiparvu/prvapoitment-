import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Adds a card — by handing off, not by collecting.
///
/// This sheet is explicitly the **tokenization placeholder**: it gathers only
/// the non-sensitive details that belong to PRV (who the card belongs to and
/// the billing postcode used for address verification), explains where the
/// card number actually goes, and then calls the injected ``CardTokenizer``.
/// The card number is entered in Stripe's own PCI-scoped sheet, and only a
/// vault token plus the last four digits ever come back — which is why no
/// field on this screen accepts a PAN.
struct AddCardSheet: View {
    @Environment(\.prvCardTokenizer) private var tokenizer
    @Environment(\.dismiss) private var dismiss

    /// Called with the vaulted method once Stripe returns one.
    let onAdded: (SavedPaymentMethod) -> Void

    @State private var cardholderName = ""
    @State private var postalCode = ""
    @State private var setAsDefault = true
    @State private var isVaulting = false
    @State private var failure: String?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case postalCode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    vaultExplainer
                    detailsCard
                    if let failure {
                        failureBanner(failure)
                    }
                }
                .padding(PRVSpacing.md)
                .padding(.bottom, PRVSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Color.prv.canvas)
            .navigationTitle("Add Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isVaulting)
                        .accessibilityLabel("Cancel adding a card")
                }
            }
            .prvBottomBar { continueButton }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var vaultExplainer: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title3)
                        .foregroundStyle(Color.prv.success)
                        .accessibilityHidden(true)
                    Text("Your card never touches this app")
                        .prvStyle(.headline)
                }

                Text("Tapping continue opens Stripe's own secure sheet. Your card number is entered there, vaulted by Stripe, and returned to PRV Beauty as a token — we only ever store the brand, the last four digits, and the expiry.")
                    .prvStyle(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Label("PCI-DSS handled by Stripe", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.success)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detailsCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                Text("Billing details")
                    .prvStyle(.headline)

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text("Cardholder name")
                        .prvStyle(.caption)
                    TextField("Sofia Laurent", text: $cardholderName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .name)
                        .onSubmit { focusedField = .postalCode }
                        .padding(PRVSpacing.sm)
                        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                        .accessibilityLabel("Cardholder name")
                }

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text("Billing postcode")
                        .prvStyle(.caption)
                    TextField("2000", text: $postalCode)
                        .textContentType(.postalCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .postalCode)
                        .padding(PRVSpacing.sm)
                        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                        .accessibilityLabel("Billing postcode")
                }

                Toggle(isOn: $setAsDefault) {
                    Text("Use as my default method")
                        .prvStyle(.body)
                }
                .tint(Color.prv.accent)
                .accessibilityHint("New bookings will be charged to this card first")

                Text("These details stay with PRV Beauty for receipts and address verification. Nothing here identifies your card number.")
                    .prvStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var continueButton: some View {
        Button {
            Task { await vault() }
        } label: {
            if isVaulting {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.prv.textOnAccent)
            } else {
                Label("Continue securely", systemImage: "lock.fill")
            }
        }
        .buttonStyle(.prvPrimary)
        .disabled(!canContinue)
        .accessibilityLabel("Continue to Stripe's secure card sheet")
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.prv.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PRVSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prv.warning.opacity(0.12), in: PRVRadius.shape(PRVRadius.md))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    /// Whether the handoff can start: a name is required for the receipt, a
    /// postcode for address verification.
    private var canContinue: Bool {
        !cardholderName.trimmed.isBlank && !postalCode.trimmed.isBlank && !isVaulting
    }

    /// Hands off to the tokenizer and reports the outcome inline.
    private func vault() async {
        guard canContinue else { return }
        focusedField = nil
        failure = nil
        isVaulting = true
        defer { isVaulting = false }
        do {
            let method = try await tokenizer.vaultCard(
                cardholderName: cardholderName.trimmed,
                postalCode: postalCode.trimmed.uppercased(),
                setAsDefault: setAsDefault
            )
            PRVHaptics.success()
            onAdded(method)
            dismiss()
        } catch let error as CardTokenizationError {
            guard error != .cancelled else { return }
            PRVHaptics.warning()
            failure = error.message
        } catch {
            PRVHaptics.warning()
            failure = PaymentsFormatting.friendlyError(error, subject: "That card")
        }
    }
}

#Preview("Add Card — Light") {
    AddCardSheet { _ in }
}

#Preview("Add Card — Dark") {
    AddCardSheet { _ in }
        .preferredColorScheme(.dark)
}
