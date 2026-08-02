import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking
#if canImport(UIKit)
import UIKit
#endif

/// Gift cards: design one, hold the ones you own, redeem the one you were
/// given.
///
/// The three jobs are genuinely different tasks rather than sections of one
/// list — designing wants the whole screen and the keyboard, the wallet wants
/// a quiet list, redeeming wants a single field — so a glass segmented
/// control switches between them and each mode owns its own empty, loading,
/// and error states.
public struct GiftCardsView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    /// The three jobs this screen does.
    private enum Mode: String, CaseIterable, Hashable {
        case design = "Buy"
        case wallet = "My Cards"
        case redeem = "Redeem"
    }

    @State private var model = GiftCardsModel()
    @State private var mode: Mode = .design

    /// Creates the gift cards screen. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                PRVSegmentedGlassControl(
                    selection: $mode,
                    options: Mode.allCases,
                    title: \.rawValue
                )
                .accessibilityLabel("Gift card section")

                switch mode {
                case .design:
                    // A finished purchase belongs in the wallet, where the
                    // new card is waiting with its code.
                    GiftCardDesigner(model: model) { mode = .wallet }
                case .wallet:
                    walletMode
                case .redeem:
                    GiftCardRedeemSection(model: model)
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Gift Cards")
        .navigationBarTitleDisplayMode(.large)
        .prvAnimation(PRVMotion.gentle, value: mode)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .prvToast($model.toast)
    }

    // MARK: - Wallet

    @ViewBuilder
    private var walletMode: some View {
        switch model.phase {
        case .loading:
            GiftCardsSkeleton()
        case .failed(let message):
            PRVEmptyState(
                systemImage: "exclamationmark.icloud",
                title: "Gift cards unavailable",
                message: message,
                actionTitle: "Try Again"
            ) {
                PRVHaptics.tap()
                reload()
            }
            .padding(.top, PRVSpacing.xl)
        case .loaded:
            loadedWallet
        }
    }

    @ViewBuilder
    private var loadedWallet: some View {
        if model.isGuest {
            PRVEmptyState(
                systemImage: "giftcard",
                title: "Your cards live here",
                message: "Sign in to see the gift cards you've bought and the ones you've been given.",
                actionTitle: "Buy a Gift Card"
            ) {
                PRVHaptics.tap()
                mode = .design
            }
            .padding(.top, PRVSpacing.xl)
        } else if model.isEmpty {
            PRVEmptyState(
                systemImage: "giftcard",
                title: "No gift cards yet",
                message: "Buy one for someone who deserves it, or redeem a code you were given.",
                actionTitle: "Design a Gift Card"
            ) {
                PRVHaptics.tap()
                mode = .design
            }
            .padding(.top, PRVSpacing.xl)
        } else {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                balanceHeader

                ForEach(model.spendableCards) { card in
                    GiftCardWalletRow(card: card, isNew: card.id == model.lastPurchasedID)
                }

                if !model.depletedCards.isEmpty {
                    PRVSectionHeader("Fully used", subtitle: "Kept for your records")
                        .padding(.top, PRVSpacing.xs)

                    ForEach(model.depletedCards) { card in
                        GiftCardWalletRow(card: card)
                    }
                }
            }
            .task {
                // The "New" flourish belongs to the moment, not to the data.
                try? await Task.sleep(for: .seconds(6))
                model.clearPurchaseHighlight()
            }
        }
    }

    private var balanceHeader: some View {
        HStack(spacing: PRVSpacing.md) {
            GradientMedallion(
                systemName: "giftcard.fill",
                gradient: Color.prv.accentGradient,
                size: 46
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Available balance")
                    .prvStyle(.caption)
                Text(model.totalBalance.formatted)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            Button("Buy") {
                PRVHaptics.tap()
                mode = .design
            }
            .buttonStyle(.prvGlass)
            .accessibilityLabel("Buy another gift card")
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }

    private func reload() {
        Task { await refresh() }
    }
}

// MARK: - Wallet row

/// One owned gift card: how much is left of what it started with, its code
/// behind a deliberate reveal, and the ways to pass it on.
///
/// The code stays masked until asked for. A gift card *is* its code — anyone
/// who reads it over your shoulder can spend it — so revealing is always an
/// explicit act.
struct GiftCardWalletRow: View {
    /// The card to render.
    let card: GiftCard
    /// Badges the card the client just bought.
    var isNew = false

    @State private var isRevealed = false
    @State private var didCopy = false

    private var isDepleted: Bool { card.remainingBalance.isZero }

    /// How much of the original value is still on the card, 0…1.
    private var remainingFraction: Double {
        let initial = card.initialBalance.amount
        guard initial > 0 else { return 0 }
        return min(max((card.remainingBalance.amount / initial).doubleValue, 0), 1)
    }

    private var shareText: String {
        "Here's a PRV Beauty gift card worth \(card.remainingBalance.formatted). Redeem it in the app with code \(card.code)."
    }

    var body: some View {
        VStack(spacing: PRVSpacing.sm) {
            HStack(spacing: PRVSpacing.md) {
                PRVProgressRing(
                    progress: remainingFraction,
                    lineWidth: 6,
                    size: 58,
                    tint: isDepleted ? AnyShapeStyle(Color.prv.textSecondary) : AnyShapeStyle(Color.prv.accentGradient)
                ) {
                    Image(systemName: "giftcard.fill")
                        .font(.subheadline)
                        .foregroundStyle(isDepleted ? Color.prv.textSecondary : Color.prv.accent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.remainingBalance.formatted)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("of \(card.initialBalance.formatted)")
                        .prvStyle(.caption)

                    if let expiresAt = card.expiresAt {
                        Text("Valid until \(expiresAt.formatted(.dateTime.month(.abbreviated).year()))")
                            .prvStyle(.caption)
                    }
                }

                Spacer(minLength: PRVSpacing.xxs)

                VStack(alignment: .trailing, spacing: PRVSpacing.xxs) {
                    if isNew {
                        PRVBadge("New", tint: Color.prv.accent)
                    } else if isDepleted {
                        PRVBadge("Used", tint: Color.prv.textSecondary)
                    }
                    if let recipient = card.recipientEmail {
                        Text(recipient)
                            .prvStyle(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summaryAccessibilityLabel)

            Divider().overlay(Color.prv.separator.opacity(0.5))

            codeRow
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .opacity(isDepleted ? 0.7 : 1)
        .prvAnimation(PRVMotion.quick, value: isRevealed)
        .prvAnimation(PRVMotion.quick, value: didCopy)
    }

    private var codeRow: some View {
        HStack(spacing: PRVSpacing.sm) {
            Text(isRevealed ? card.code : MembershipsFormatting.maskedCode(card.code))
                .font(.footnote.weight(.semibold))
                .monospaced()
                .foregroundStyle(isRevealed ? Color.prv.textPrimary : Color.prv.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(isRevealed ? "Code \(spelledOutCode)" : "Code hidden")

            Spacer(minLength: PRVSpacing.xxs)

            Button {
                PRVHaptics.tap()
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide the code" : "Reveal the code")

            Button {
                PRVHaptics.success()
                GiftCardClipboard.copy(card.code)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(didCopy ? Color.prv.success : Color.prv.accent)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Code copied" : "Copy the code")

            ShareLink(
                item: shareText,
                subject: Text("A PRV Beauty gift card"),
                message: Text(shareText)
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Share this gift card")
        }
    }

    /// Spaced out so VoiceOver reads the code one character at a time —
    /// the difference between a transcribable code and a mumbled word.
    private var spelledOutCode: String {
        card.code.map(String.init).joined(separator: " ")
    }

    private var summaryAccessibilityLabel: String {
        var parts = ["Gift card", "\(card.remainingBalance.formatted) left of \(card.initialBalance.formatted)"]
        if isNew { parts.append("new") }
        if isDepleted { parts.append("fully used") }
        if let recipient = card.recipientEmail { parts.append("for \(recipient)") }
        if let expiresAt = card.expiresAt {
            parts.append("valid until \(expiresAt.formatted(.dateTime.month(.wide).year()))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Redeem

/// The redeem-by-code panel: one field, one button, and an outcome that stays
/// on screen until it is dealt with.
struct GiftCardRedeemSection: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    /// Shared screen model — owns the redemption call.
    let model: GiftCardsModel

    @State private var code = ""
    @FocusState private var isCodeFocused: Bool

    private var canSubmit: Bool {
        session.currentUser != nil && code.trimmed.count >= 6 && !model.isRedeeming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                PRVSectionHeader(
                    "Redeem a code",
                    subtitle: "From your gift card email, or the printed card"
                )

                TextField("GIFT-XXXX-XXXX", text: $code)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isCodeFocused)
                    .submitLabel(.go)
                    .onSubmit { redeem() }
                    .onChange(of: code) { _, newValue in
                        // Typing a new code invalidates the last result —
                        // but emptying the field after a success (which this
                        // view does itself) must not wipe the good news.
                        guard !newValue.isEmpty else { return }
                        model.clearRedeemOutcome()
                    }
                    .prvGlassCard()
                    .accessibilityLabel("Gift card code")

                Text("Codes never contain the letters I or O, or the digits 0 or 1.")
                    .prvStyle(.caption)
            }

            Button {
                redeem()
            } label: {
                if model.isRedeeming {
                    ProgressView()
                        .tint(Color.prv.textOnAccent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(session.currentUser == nil ? "Sign in to redeem" : "Add to My Cards")
                }
            }
            .buttonStyle(.prvPrimary)
            .disabled(!canSubmit)
            .accessibilityLabel("Redeem this gift card code")

            if let outcome = model.redeemOutcome {
                outcomeView(outcome)
                    .transition(.opacity.combined(with: .offset(y: PRVSpacing.xs)))
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.redeemOutcome)
    }

    @ViewBuilder
    private func outcomeView(_ outcome: GiftCardsModel.RedeemOutcome) -> some View {
        switch outcome {
        case .success(let card):
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                GiftCardPreviewCard(
                    amount: card.remainingBalance,
                    message: card.message,
                    code: card.code,
                    expiresAt: card.expiresAt
                )

                HStack(alignment: .top, spacing: PRVSpacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.prv.success)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        Text("\(card.remainingBalance.formatted) is yours")
                            .prvStyle(.headline)
                        Text("The card is in My Cards and will be offered automatically at checkout.")
                            .prvStyle(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .prvGlassCard()
                .overlay {
                    PRVRadius.shape(PRVRadius.lg)
                        .strokeBorder(Color.prv.success.opacity(0.4), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
            }

        case .failure(let message):
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.prv.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .prvGlassCard()
            .overlay {
                PRVRadius.shape(PRVRadius.lg)
                    .strokeBorder(Color.prv.warning.opacity(0.4), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func redeem() {
        guard canSubmit else { return }
        isCodeFocused = false
        let entered = code
        Task {
            let succeeded = await model.redeem(code: entered, using: deps)
            if succeeded { code = "" }
        }
    }
}

// MARK: - Clipboard

/// Copies text to the system clipboard.
///
/// SwiftUI has no pasteboard API of its own, so this is the single place the
/// module touches UIKit — wrapped in a capability check so the module still
/// builds anywhere.
enum GiftCardClipboard {
    /// Puts `text` on the general pasteboard.
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Skeleton

/// The gift-card wallet's loading state.
struct GiftCardsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSkeleton(height: 78, radius: PRVRadius.lg)
            PRVSkeleton(height: 124, radius: PRVRadius.lg)
            PRVSkeleton(height: 124, radius: PRVRadius.lg)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading gift cards")
    }
}

// MARK: - Previews

#Preview("Gift Cards — Client") {
    NavigationStack {
        GiftCardsView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
}

#Preview("Gift Cards — Dark") {
    NavigationStack {
        GiftCardsView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
    .preferredColorScheme(.dark)
}

#Preview("Gift Card — Wallet Row") {
    VStack(spacing: PRVSpacing.md) {
        GiftCardWalletRow(
            card: GiftCard(
                code: "GIFT-K7M2-P4XQ",
                initialBalance: Money(100),
                remainingBalance: Money(Decimal(125) / 2),
                purchaserID: PreviewData.client.id,
                recipientEmail: "amelie@example.com",
                expiresAt: Date.now.addingTimeInterval(60 * 60 * 24 * 400)
            ),
            isNew: true
        )

        GiftCardWalletRow(
            card: GiftCard(
                code: "GIFT-QW34-ZZ88",
                initialBalance: Money(50),
                remainingBalance: Money(0)
            )
        )
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}
