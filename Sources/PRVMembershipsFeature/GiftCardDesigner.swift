import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Preview card

/// The gift card itself, drawn on the brand gradient with a soft specular
/// sheen — the object the client is actually buying.
///
/// It is used twice: live in the designer, where every keystroke updates it,
/// and again when a redeemed card is handed over. Amount changes animate with
/// a numeric text transition so the card feels like it is being filled in,
/// not redrawn.
struct GiftCardPreviewCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Value on the card.
    let amount: Money
    /// Who it is for; `nil` keeps it for the buyer.
    var recipientEmail: String?
    /// Optional gift message.
    var message: String?
    /// The issued code, once there is one.
    var code: String?
    /// When the card stops being redeemable.
    var expiresAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(alignment: .top) {
                Text("PRV BEAUTY")
                    .font(.caption.weight(.black))
                    .tracking(2)
                Spacer(minLength: PRVSpacing.xs)
                Image(systemName: "giftcard.fill")
                    .font(.title3)
            }

            Spacer(minLength: PRVSpacing.xs)

            Text(amount.formatted)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let trimmedMessage, !trimmedMessage.isEmpty {
                Text("“\(trimmedMessage)”")
                    .font(.footnote.italic())
                    .lineLimit(2)
                    .opacity(0.95)
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipientLine)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Text(footerLine)
                        .font(.caption2)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                Spacer(minLength: PRVSpacing.xs)
            }
        }
        .foregroundStyle(Color.prv.textOnAccent)
        .padding(PRVSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Card proportions at normal type sizes; at accessibility sizes the
        // card grows to fit its text rather than truncating the message.
        .modifier(CreditCardProportions(ratio: dynamicTypeSize.isAccessibilitySize ? nil : 1.586))
        .background(Color.prv.accentGradient)
        .overlay {
            // A slow diagonal sheen: the light catching a laminated card.
            LinearGradient(
                colors: [.white.opacity(0.22), .clear, .white.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
        .clipShape(PRVRadius.shape(PRVRadius.xl))
        .overlay {
            PRVRadius.shape(PRVRadius.xl)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        }
        .prvSoftShadow()
        .prvAnimation(PRVMotion.quick, value: amount.amount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var trimmedMessage: String? { message?.trimmed }

    private var recipientLine: String {
        guard let recipient = recipientEmail?.trimmed, !recipient.isEmpty else {
            return "For you"
        }
        return "For \(recipient)"
    }

    private var footerLine: String {
        if let code { return code }
        if let expiresAt {
            return "Valid until \(expiresAt.formatted(.dateTime.month(.abbreviated).year()))"
        }
        return "Valid for \(GiftCardRules.validityYears) years"
    }

    private var accessibilityLabel: String {
        var parts = ["Gift card, \(amount.formatted)", recipientLine]
        if let trimmedMessage, !trimmedMessage.isEmpty { parts.append("message: \(trimmedMessage)") }
        return parts.joined(separator: ", ")
    }
}

/// Applies credit-card proportions, or none at all when the text needs the
/// room more than the silhouette does.
private struct CreditCardProportions: ViewModifier {
    /// Width-to-height ratio, or `nil` to let the content size itself.
    let ratio: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content
        }
    }
}

// MARK: - Designer

/// The gift card designer: choose a value, say who it is for, add a note, and
/// watch the card fill in as you type.
///
/// Validation is shared with the CTA through ``GiftCardRules``, so the hint
/// under a field and the disabled state of the button can never disagree.
struct GiftCardDesigner: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    /// Shared screen model — owns the purchase call.
    let model: GiftCardsModel
    /// Called after a successful purchase, so the parent can show the wallet.
    let onPurchased: () -> Void

    /// Which field currently has the keyboard.
    private enum Field: Hashable {
        case customAmount
        case email
        case message
    }

    @State private var selectedPreset: Decimal = 50
    @State private var isCustom = false
    @State private var customAmount: Decimal = 75
    @State private var recipientEmail = ""
    @State private var message = ""
    @FocusState private var focusedField: Field?

    /// Currency to price in: whatever the client's existing cards use,
    /// falling back to the platform default.
    private var currency: Currency { model.totalBalance.currency }

    private var amount: Money {
        Money(isCustom ? customAmount : selectedPreset, currency)
    }

    private var amountProblem: String? { GiftCardRules.amountProblem(amount.amount) }

    private var isRecipientValid: Bool { GiftCardRules.isRecipientAcceptable(recipientEmail) }

    private var canBuy: Bool {
        session.currentUser != nil
            && amountProblem == nil
            && isRecipientValid
            && !model.isPurchasing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            GiftCardPreviewCard(
                amount: amount,
                recipientEmail: recipientEmail,
                message: message
            )

            amountSection
            recipientSection
            buyButton
        }
        .prvAnimation(PRVMotion.spring, value: isCustom)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityLabel("Dismiss the keyboard")
            }
        }
    }

    // MARK: Amount

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Amount", subtitle: "Pick a value, or set your own")

            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(GiftCardRules.presets, id: \.self) { preset in
                    PRVChip(
                        Money(preset, currency).formatted,
                        isSelected: !isCustom && selectedPreset == preset
                    ) {
                        isCustom = false
                        selectedPreset = preset
                        focusedField = nil
                    }
                }
                PRVChip("Custom", systemImage: "slider.horizontal.3", isSelected: isCustom) {
                    isCustom = true
                    focusedField = .customAmount
                }
            }

            if isCustom {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    HStack(spacing: PRVSpacing.xs) {
                        Text(currency.symbol)
                            .prvStyle(.headline)
                            .accessibilityHidden(true)

                        TextField(
                            "Amount",
                            value: $customAmount,
                            format: .number.precision(.fractionLength(0 ... 2))
                        )
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .customAmount)
                        .accessibilityLabel("Custom gift card amount in \(currency.rawValue)")
                    }
                    .prvGlassCard()

                    if let amountProblem {
                        ValidationHint(text: amountProblem)
                    } else {
                        Text("Between \(Money(GiftCardRules.minimumAmount, currency).formatted) and \(Money(GiftCardRules.maximumAmount, currency).formatted).")
                            .prvStyle(.caption)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -PRVSpacing.xs)))
            }
        }
    }

    // MARK: Recipient

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Recipient", subtitle: "Leave empty to keep it for yourself")

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                TextField("Email address", text: $recipientEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .message }
                    .accessibilityLabel("Recipient email address")

                Divider().overlay(Color.prv.separator)

                TextField("Message (optional)", text: $message, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .focused($focusedField, equals: .message)
                    .accessibilityLabel("Gift message")
                    .onChange(of: message) { _, newValue in
                        // Keep the note within what the card can carry.
                        if newValue.count > GiftCardRules.messageLimit {
                            message = String(newValue.prefix(GiftCardRules.messageLimit))
                        }
                    }
            }
            .prvGlassCard()

            if !isRecipientValid {
                ValidationHint(text: "That email address doesn't look right.")
            } else if !recipientEmail.trimmed.isEmpty {
                Text("We'll email the card and its code the moment the payment clears.")
                    .prvStyle(.caption)
            }
        }
    }

    // MARK: Buy

    private var buyButton: some View {
        VStack(spacing: PRVSpacing.xs) {
            Button {
                buy()
            } label: {
                if model.isPurchasing {
                    ProgressView()
                        .tint(Color.prv.textOnAccent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(session.currentUser == nil ? "Sign in to buy" : "Buy for \(amount.formatted)")
                }
            }
            .buttonStyle(.prvPrimary)
            .disabled(!canBuy)
            .accessibilityLabel(
                session.currentUser == nil
                    ? "Sign in to buy a gift card"
                    : "Buy a gift card for \(amount.formatted)"
            )

            Text("Redeemable at every PRV salon for \(GiftCardRules.validityYears) years.")
                .prvStyle(.caption)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: Actions

    private func buy() {
        guard let user = session.currentUser, canBuy else { return }
        focusedField = nil
        PRVHaptics.impact()
        let purchaseAmount = amount
        let recipient = recipientEmail
        let note = message
        Task {
            let card = await model.purchase(
                amount: purchaseAmount,
                recipientEmail: recipient,
                message: note,
                for: user,
                using: deps
            )
            guard card != nil else { return }
            recipientEmail = ""
            message = ""
            onPurchased()
        }
    }
}

// MARK: - Validation hint

/// A short, warm correction under a field — never a red wall of text.
struct ValidationHint: View {
    /// What needs fixing.
    let text: String

    var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(Color.prv.warning)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Gift Card — Preview Card") {
    VStack(spacing: PRVSpacing.lg) {
        GiftCardPreviewCard(
            amount: Money(100),
            recipientEmail: "amelie@example.com",
            message: "Happy birthday — go and be spoiled."
        )
        GiftCardPreviewCard(
            amount: Money(50),
            code: "GIFT-K7M2-P4XQ",
            expiresAt: Date.now.addingTimeInterval(60 * 60 * 24 * 365)
        )
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Gift Card — Designer") {
    ScrollView {
        GiftCardDesigner(model: GiftCardsModel()) {}
            .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
    .environment(UserSession.previewClient)
}
