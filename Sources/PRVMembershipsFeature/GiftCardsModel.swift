import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model backing ``GiftCardsView``.
///
/// Three jobs share one model because they share one balance: designing and
/// buying a card, holding the cards you own, and redeeming a code someone
/// gave you. Redemption keeps an explicit success/failure outcome rather than
/// only a toast — a wrong code is a state the client needs to sit with and
/// correct, not a message that slides away after two seconds.
@Observable
@MainActor
final class GiftCardsModel {
    /// The result of the last redemption attempt.
    enum RedeemOutcome: Equatable, Sendable {
        /// The code was accepted; the card is now in the wallet.
        case success(GiftCard)
        /// The code was rejected, with warm copy explaining why.
        case failure(String)
    }

    // MARK: - State

    private(set) var phase: MembershipsPhase = .loading
    /// Cards the client owns, newest first.
    private(set) var cards: [GiftCard] = []
    /// `true` while a purchase is in flight.
    private(set) var isPurchasing = false
    /// `true` while a redemption is in flight.
    private(set) var isRedeeming = false
    /// `true` when nobody is signed in.
    private(set) var isGuest = false
    /// Outcome of the last redemption, rendered inline under the field.
    private(set) var redeemOutcome: RedeemOutcome?
    /// The card bought in this session, badged "New" at the top of the wallet.
    private(set) var lastPurchasedID: GiftCard.ID?
    /// Transient feedback.
    var toast: PRVToast?

    private var hasLoadedOnce = false

    /// Creates an empty model. All data arrives through ``load(for:using:)``.
    init() {}

    // MARK: - Derived

    /// `true` when the client holds no cards at all.
    var isEmpty: Bool { cards.isEmpty }

    /// Combined remaining balance. Only same-currency cards are summed — a
    /// mixed wallet reports its dominant currency rather than asserting.
    var totalBalance: Money {
        guard let currency = cards.first?.remainingBalance.currency else { return .zero() }
        return cards
            .filter { $0.remainingBalance.currency == currency }
            .reduce(Money.zero(currency)) { $0 + $1.remainingBalance }
    }

    /// Cards with money left on them.
    var spendableCards: [GiftCard] { cards.filter { !$0.remainingBalance.isZero } }

    /// Fully spent cards, kept for the record.
    var depletedCards: [GiftCard] { cards.filter(\.remainingBalance.isZero) }

    // MARK: - Loading

    /// Loads the client's gift cards.
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            cards = []
            isGuest = true
            phase = .loaded
            return
        }

        isGuest = false
        if !hasLoadedOnce { phase = .loading }

        do {
            let loaded = try await deps.payments.giftCards(userID: user.id)
            cards = loaded.sorted { $0.createdAt > $1.createdAt }
            phase = .loaded
            hasLoadedOnce = true
        } catch {
            let message = MembershipsFormatting.friendlyError(error, subject: "Your gift cards")
            if hasLoadedOnce {
                toast = .warning(message)
                phase = .loaded
            } else {
                phase = .failed(message)
            }
        }
    }

    // MARK: - Buying

    /// Buys a gift card and puts it at the head of the wallet.
    ///
    /// The code is minted client-side only as a placeholder for the optimistic
    /// row; whatever the repository returns is what gets stored, so a
    /// server-issued code always wins.
    ///
    /// - Returns: The purchased card, or `nil` when the purchase failed.
    @discardableResult
    func purchase(
        amount: Money,
        recipientEmail: String,
        message: String,
        for user: User,
        using deps: PRVDependencies
    ) async -> GiftCard? {
        guard !isPurchasing else { return nil }
        if let problem = GiftCardRules.amountProblem(amount.amount) {
            // The designer disables the CTA for this, but the model is the
            // last line of defence before money moves.
            toast = .warning(problem)
            return nil
        }

        isPurchasing = true
        defer { isPurchasing = false }

        let recipient = recipientEmail.trimmed
        let note = message.trimmed
        let draft = GiftCard(
            code: GiftCardCodeFactory.make(),
            initialBalance: amount,
            remainingBalance: amount,
            purchaserID: user.id,
            recipientEmail: recipient.isEmpty ? nil : recipient,
            message: note.isEmpty ? nil : String(note.prefix(GiftCardRules.messageLimit)),
            expiresAt: Calendar.current.date(byAdding: .year, value: GiftCardRules.validityYears, to: .now)
        )

        do {
            let purchased = try await deps.payments.purchaseGiftCard(draft)
            cards.insert(purchased, at: 0)
            lastPurchasedID = purchased.id
            PRVHaptics.success()
            toast = .success(
                purchased.recipientEmail.map { "Gift card on its way to \($0)" }
                    ?? "Gift card ready — \(purchased.remainingBalance.formatted)"
            )
            return purchased
        } catch {
            PRVHaptics.error()
            toast = .error(MembershipsFormatting.friendlyError(error, subject: "Gift cards"))
            return nil
        }
    }

    // MARK: - Redeeming

    /// Redeems a gift-card code into the wallet.
    ///
    /// - Returns: `true` when the code was accepted.
    @discardableResult
    func redeem(code: String, using deps: PRVDependencies) async -> Bool {
        let cleaned = code.trimmed.uppercased()
        guard !isRedeeming, !cleaned.isEmpty else { return false }

        isRedeeming = true
        defer { isRedeeming = false }
        redeemOutcome = nil

        do {
            let card = try await deps.payments.redeemGiftCard(code: cleaned)
            if let index = cards.firstIndex(where: { $0.id == card.id }) {
                cards[index] = card
            } else {
                cards.insert(card, at: 0)
            }
            redeemOutcome = .success(card)
            PRVHaptics.success()
            return true
        } catch {
            redeemOutcome = .failure(Self.redemptionFailure(for: error))
            PRVHaptics.error()
            return false
        }
    }

    /// Clears the inline redemption result — called as soon as the client
    /// starts typing a different code.
    func clearRedeemOutcome() {
        guard redeemOutcome != nil else { return }
        redeemOutcome = nil
    }

    /// Clears the "New" highlight once the client has seen it.
    func clearPurchaseHighlight() {
        lastPurchasedID = nil
    }

    // MARK: - Helpers

    /// Redemption failures deserve their own copy: "not found" here means a
    /// mistyped or already-used code, not a broken screen.
    nonisolated static func redemptionFailure(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "We couldn't redeem that code. Check it and try again."
        }
        switch apiError {
        case .notFound:
            return "We don't recognise that code. Check for typos — it's easy to mix up letters and numbers."
        case .conflict:
            return "That card has already been redeemed."
        case .offline, .network:
            return "You appear to be offline. Reconnect and try the code again."
        case .rateLimited:
            return "Too many attempts. Wait a moment before trying again."
        case .unauthorized, .forbidden:
            return "Please sign in again to redeem a card."
        case .server, .decoding:
            return "Our servers are momentarily busy. Please try again shortly."
        }
    }
}
