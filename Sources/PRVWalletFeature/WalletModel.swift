import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVLoyaltyKit
import PRVModels
import PRVNetworking

/// Screen model backing `WalletView`.
///
/// Loads the whole financial picture concurrently with `async let` — store credit,
/// ledger, gift cards, invoices, saved methods, loyalty balance, membership — so the
/// wallet assembles as fast as the slowest repository rather than sequentially.
///
/// The **balance** is the screen's spine: if store credit or the loyalty profile
/// cannot be read, the screen reports a failure rather than showing a plausible but
/// wrong number. Everything else degrades to an empty section, because a missing
/// invoice list is not worth blocking a balance.
@Observable
@MainActor
final class WalletModel {
    // MARK: State

    private(set) var phase: WalletPhase = .loading
    /// Spendable store credit — cashback, top-ups, and redeemed gift cards.
    private(set) var storeCredit: Money = .zero()
    /// Spendable loyalty points.
    private(set) var points = 0
    /// The client's current loyalty tier, shown on the balance card.
    private(set) var tier: LoyaltyTier = .bronze
    /// Ledger grouped by month, newest month first.
    private(set) var months: [TransactionMonth] = []
    private(set) var giftCards: [GiftCard] = []
    private(set) var invoices: [Invoice] = []
    private(set) var savedMethods: [SavedPaymentMethod] = []
    /// The membership to headline: the active one, else the most recent.
    private(set) var membership: MembershipSubscription?
    /// `true` while a gift-card purchase or redemption is in flight.
    private(set) var isWorking = false
    /// `true` when nobody is signed in — the wallet shows a sign-in invitation.
    private(set) var isGuest = false
    /// Transient feedback (purchase confirmed, redemption failed…).
    var toast: PRVToast?

    /// Set after the first successful load; later refreshes keep content on screen
    /// instead of flashing skeletons.
    private var hasLoadedOnce = false

    /// Creates an empty model. All data arrives through ``load(for:using:)``.
    init() {}

    // MARK: Derived

    /// `true` when the client has never had any wallet activity at all.
    var hasNoActivity: Bool {
        months.isEmpty && giftCards.isEmpty && invoices.isEmpty
    }

    /// Combined remaining balance across every gift card the client holds.
    var giftCardBalance: Money {
        guard let currency = giftCards.first?.remainingBalance.currency else { return .zero() }
        return giftCards
            .filter { $0.remainingBalance.currency == currency }
            .reduce(Money.zero(currency)) { $0 + $1.remainingBalance }
    }

    /// The default saved payment method, if one is marked.
    var defaultMethod: SavedPaymentMethod? {
        savedMethods.first(where: \.isDefault) ?? savedMethods.first
    }

    // MARK: Loading

    /// Loads every wallet section concurrently. Safe to call repeatedly
    /// (pull-to-refresh, sign-in changes).
    ///
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            reset()
            isGuest = true
            phase = .loaded
            return
        }

        isGuest = false
        if !hasLoadedOnce { phase = .loading }

        async let creditTask = deps.payments.storeCreditBalance(userID: user.id)
        async let profileTask = deps.loyalty.profile(userID: user.id)
        async let transactionsTask = deps.payments.walletTransactions(userID: user.id)
        async let giftCardsTask = deps.payments.giftCards(userID: user.id)
        async let invoicesTask = deps.payments.invoices(userID: user.id)
        async let methodsTask = deps.payments.savedMethods(userID: user.id)
        async let subscriptionsTask = deps.memberships.subscriptions(userID: user.id)

        var balanceFailure: (any Error)?
        do {
            let credit = try await creditTask
            let profile = try await profileTask
            storeCredit = credit
            points = profile.spendablePoints
            tier = profile.tier
        } catch {
            balanceFailure = error
        }

        // Secondary sections never block the balance: a failure becomes an empty
        // section with its own empty state, not a screen-wide error.
        months = Self.groupByMonth((try? await transactionsTask) ?? [], calendar: .current)
        giftCards = ((try? await giftCardsTask) ?? []).sorted { $0.createdAt > $1.createdAt }
        invoices = ((try? await invoicesTask) ?? []).sorted { $0.issuedAt > $1.issuedAt }
        savedMethods = (try? await methodsTask) ?? []

        let subscriptions = (try? await subscriptionsTask) ?? []
        membership = subscriptions.first { $0.status == .active }
            ?? subscriptions.max { $0.startedAt < $1.startedAt }

        if let balanceFailure {
            let message = WalletFormatting.friendlyError(balanceFailure, subject: "Your wallet")
            if hasLoadedOnce {
                // Keep the last known balance on screen and mention the hiccup quietly.
                toast = .warning(message)
                phase = .loaded
            } else {
                phase = .failed(message)
            }
        } else {
            phase = .loaded
            hasLoadedOnce = true
        }
    }

    /// Clears every field — used when the session signs out.
    private func reset() {
        storeCredit = .zero()
        points = 0
        tier = .bronze
        months = []
        giftCards = []
        invoices = []
        savedMethods = []
        membership = nil
        hasLoadedOnce = false
    }

    // MARK: Gift cards

    /// Buys a gift card for `amount` and prepends it to the carousel.
    ///
    /// - Returns: `true` when the purchase succeeded, so the sheet can dismiss itself.
    @discardableResult
    func purchaseGiftCard(
        amount: Money,
        recipientEmail: String?,
        message: String?,
        for user: User,
        using deps: PRVDependencies
    ) async -> Bool {
        guard !isWorking, amount.amount > 0 else { return false }
        isWorking = true
        defer { isWorking = false }

        let trimmedEmail = recipientEmail?.trimmed
        let trimmedMessage = message?.trimmed
        let card = GiftCard(
            code: GiftCardCodeFactory.make(),
            initialBalance: amount,
            remainingBalance: amount,
            purchaserID: user.id,
            recipientEmail: (trimmedEmail?.isEmpty ?? true) ? nil : trimmedEmail,
            message: (trimmedMessage?.isEmpty ?? true) ? nil : trimmedMessage,
            expiresAt: Calendar.current.date(byAdding: .year, value: 2, to: .now)
        )

        do {
            let purchased = try await deps.payments.purchaseGiftCard(card)
            giftCards.insert(purchased, at: 0)
            PRVHaptics.success()
            toast = .success("Gift card ready — \(purchased.remainingBalance.formatted)")
            return true
        } catch {
            PRVHaptics.error()
            toast = .error(WalletFormatting.friendlyError(error, subject: "Gift cards"))
            return false
        }
    }

    /// Redeems a gift-card code into the wallet.
    ///
    /// - Returns: `true` when the code was accepted.
    @discardableResult
    func redeemGiftCard(code: String, using deps: PRVDependencies) async -> Bool {
        let cleaned = code.trimmed.uppercased()
        guard !isWorking, !cleaned.isEmpty else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            let card = try await deps.payments.redeemGiftCard(code: cleaned)
            if let index = giftCards.firstIndex(where: { $0.id == card.id }) {
                giftCards[index] = card
            } else {
                giftCards.insert(card, at: 0)
            }
            PRVHaptics.success()
            toast = .success("Added \(card.remainingBalance.formatted) to your wallet")
            return true
        } catch {
            PRVHaptics.error()
            toast = .error(WalletFormatting.friendlyError(error, subject: "That gift card"))
            return false
        }
    }

    // MARK: Grouping

    /// Groups movements into months, newest month and newest movement first.
    ///
    /// `nonisolated` and calendar-injected so it stays a pure function that can be
    /// exercised without a main-actor hop.
    nonisolated static func groupByMonth(
        _ transactions: [WalletTransaction],
        calendar: Calendar
    ) -> [TransactionMonth] {
        let ordered = transactions.sorted { $0.createdAt > $1.createdAt }
        var monthOrder: [Date] = []
        var buckets: [Date: [WalletTransaction]] = [:]

        for transaction in ordered {
            let components = calendar.dateComponents([.year, .month], from: transaction.createdAt)
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: transaction.createdAt)
            if buckets[start] == nil { monthOrder.append(start) }
            buckets[start, default: []].append(transaction)
        }

        return monthOrder.map { TransactionMonth(id: $0, transactions: buckets[$0] ?? []) }
    }
}
