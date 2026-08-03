import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The Beauty Wallet: one screen that answers "what do I have, what did I spend, and
/// what am I entitled to".
///
/// A brand-gradient balance header with a slow specular sheen leads into the ledger
/// grouped by month, a gift-card carousel with buy/redeem sheets, invoices with a
/// share action, a saved-methods summary, and membership standing. Loading shows
/// shimmering skeletons, failure shows warm copy with a retry, and an untouched
/// wallet shows an invitation rather than an empty table.
///
/// Data flows exclusively through `@Environment(\.prvDependencies)`; cross-feature
/// navigation goes through the shared `AppRouter`.
public struct WalletView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = WalletModel()
    @State private var isBuyingGiftCard = false
    @State private var isRedeemingGiftCard = false

    /// Creates the wallet. All dependencies come from the environment; the
    /// initializer stays empty by contract.
    public init() {}

    public var body: some View {
        ScrollView {
            Group {
                switch model.phase {
                case .loading:
                    WalletSkeleton()
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    content
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.large)
        // The balance card is the headline; once the client scrolls past it
        // into the ledger, the bar steps aside and comes back on the way up.
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .sheet(isPresented: $isBuyingGiftCard) {
            BuyGiftCardSheet(model: model)
        }
        .sheet(isPresented: $isRedeemingGiftCard) {
            RedeemGiftCardSheet(model: model)
        }
        .prvToast($model.toast)
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if model.isGuest {
            PRVEmptyState(
                systemImage: "wallet.pass",
                title: "Your wallet is waiting",
                message: "Sign in to see your store credit, gift cards, invoices, and rewards in one place.",
                actionTitle: "Explore Salons"
            ) {
                PRVHaptics.tap()
                router.selectedTab = .discover
            }
            .padding(.top, PRVSpacing.xxl)
        } else {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                WalletBalanceCard(
                    storeCredit: model.storeCredit,
                    points: model.points,
                    tier: model.tier
                ) {
                    router.push(.loyalty)
                }

                giftCardsSection
                transactionsSection
                invoicesSection
                paymentMethodsSection

                MembershipStatusCard(subscription: model.membership) {
                    router.push(.memberships(salonID: nil))
                }
            }
        }
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "exclamationmark.icloud",
            title: "Wallet unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: - Gift cards

    private var giftCardsSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(
                "Gift Cards",
                subtitle: model.giftCards.isEmpty ? nil : "\(model.giftCardBalance.formatted) available",
                actionTitle: "Buy"
            ) {
                PRVHaptics.tap()
                isBuyingGiftCard = true
            }

            if model.giftCards.isEmpty {
                emptyGiftCards
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: PRVSpacing.md) {
                        ForEach(model.giftCards) { card in
                            GiftCardTile(card: card)
                        }
                        redeemTile
                    }
                    .padding(.vertical, PRVSpacing.xxs)
                }
                .scrollIndicators(.hidden)
                // Let the carousel bleed to the screen edge while the section keeps
                // its reading margin.
                .padding(.horizontal, -PRVSpacing.lg)
                .contentMargins(.horizontal, PRVSpacing.lg, for: .scrollContent)
            }
        }
    }

    private var emptyGiftCards: some View {
        HStack(spacing: PRVSpacing.md) {
            Image(systemName: "giftcard")
                .font(.title3)
                .foregroundStyle(Color.prv.gold)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text("No gift cards yet")
                    .prvStyle(.headline)
                Text("Buy one for a friend, or redeem a code you were given.")
                    .prvStyle(.footnote)
            }

            Spacer(minLength: PRVSpacing.xs)

            Button("Redeem") {
                PRVHaptics.tap()
                isRedeemingGiftCard = true
            }
            .buttonStyle(.prvGlass)
            .accessibilityLabel("Redeem a gift card code")
        }
        .prvGlassCard()
    }

    private var redeemTile: some View {
        Button {
            PRVHaptics.tap()
            isRedeemingGiftCard = true
        } label: {
            VStack(spacing: PRVSpacing.xs) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.prv.accent)
                Text("Redeem a code")
                    .prvStyle(.footnote)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 130, height: 132)
            .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Redeem a gift card code")
    }

    // MARK: - Ledger

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSectionHeader("Activity", subtitle: "Every movement on your wallet")

            if model.months.isEmpty {
                PRVEmptyState(
                    systemImage: "clock.arrow.circlepath",
                    title: "Nothing here yet",
                    message: "Payments, cashback, and refunds will appear here as soon as you book.",
                    actionTitle: "Find a Salon"
                ) {
                    PRVHaptics.tap()
                    router.selectedTab = .discover
                }
                .padding(.vertical, PRVSpacing.lg)
            } else {
                ForEach(model.months) { month in
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        HStack {
                            Text(month.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.prv.textSecondary)
                            Spacer()
                            Text(WalletFormatting.signed(month.net))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WalletFormatting.signedTint(month.net))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)

                        VStack(spacing: PRVSpacing.xs) {
                            ForEach(month.transactions) { transaction in
                                WalletTransactionRow(transaction: transaction)
                                if transaction.id != month.transactions.last?.id {
                                    Divider().overlay(Color.prv.separator.opacity(0.5))
                                }
                            }
                        }
                        .prvGlassCard()
                    }
                }
            }
        }
    }

    // MARK: - Invoices

    @ViewBuilder
    private var invoicesSection: some View {
        if !model.invoices.isEmpty {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader("Invoices", subtitle: "Share or archive your receipts")

                VStack(spacing: PRVSpacing.xs) {
                    ForEach(model.invoices) { invoice in
                        InvoiceRow(invoice: invoice)
                        if invoice.id != model.invoices.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .prvGlassCard()
            }
        }
    }

    // MARK: - Payment methods

    @ViewBuilder
    private var paymentMethodsSection: some View {
        if !model.savedMethods.isEmpty {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(
                    "Payment Methods",
                    subtitle: model.defaultMethod.map { "\($0.displayLabelOrKind) is your default" }
                )

                VStack(spacing: PRVSpacing.xs) {
                    ForEach(model.savedMethods) { method in
                        SavedMethodRow(method: method)
                        if method.id != model.savedMethods.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .prvGlassCard()
            }
        }
    }

    // MARK: - Actions

    /// Re-runs the full concurrent load (used by the failure-state retry).
    private func reload() {
        let user = session.currentUser
        let deps = deps
        Task { await model.load(for: user, using: deps) }
    }

    /// MainActor-isolated refresh entry point for pull-to-refresh.
    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }
}

// MARK: - Previews

#Preview("Wallet — Client") {
    NavigationStack {
        WalletView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
}

#Preview("Wallet — Dark") {
    NavigationStack {
        WalletView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
    .preferredColorScheme(.dark)
}

#Preview("Wallet — Guest") {
    NavigationStack {
        WalletView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .wallet))
}
