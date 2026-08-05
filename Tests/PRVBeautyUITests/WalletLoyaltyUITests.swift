import XCTest

/// The Beauty Wallet and the loyalty programme for a signed-in client: the
/// balance card, the ledger, and the tier hero all have to render from the
/// demo backend without a network.
final class WalletLoyaltyUITests: PRVUITestCase {
    func testWalletRendersTheBalanceCardForASignedInClient() {
        launch(as: .client)
        selectTab(PRVElement.tabWallet)

        expect(app.navigationBars["Wallet"], "the Wallet screen")
        expect(anyElement(PRVElement.walletBalanceCard), "the Beauty Wallet balance card")

        // The demo client is a Gold member, and the card says so.
        expect(
            element(app.staticTexts, labelled: "Store credit"),
            "the store-credit label"
        )
        // …and this is a signed-in wallet, not the guest state.
        XCTAssertFalse(
            app.staticTexts["Your wallet is waiting"].exists,
            "A signed-in client must not see the guest wallet state."
        )
    }

    func testWalletShowsItsSections() {
        launch(as: .client)
        selectTab(PRVElement.tabWallet)
        expect(app.navigationBars["Wallet"], "the Wallet screen")

        expect(element(app.staticTexts, labelled: "Gift Cards"), "the gift cards section")
        // Nothing has been bought in a fresh demo session, so the section
        // explains itself instead of showing an empty carousel.
        expect(app.staticTexts["No gift cards yet"], "the gift-card empty state")
    }

    func testWalletOpensTheLoyaltyScreen() {
        launch(as: .client)
        selectTab(PRVElement.tabWallet)

        tap(anyElement(PRVElement.walletBalanceCard), "the balance card")

        expect(app.navigationBars["Rewards"], "the loyalty screen")
        expect(anyElement(PRVElement.loyaltyTierHero), "the tier hero")
    }

    func testLoyaltyShowsTierProgressAndTheDailyReward() {
        launch(as: .client)
        selectTab(PRVElement.tabWallet)
        tap(anyElement(PRVElement.walletBalanceCard), "the balance card")
        expect(app.navigationBars["Rewards"], "the loyalty screen")

        // The demo profile sits at 6,450 XP — Gold, mid-way to Diamond.
        expect(element(app.staticTexts, labelled: "Gold"), "the current tier")
        expect(element(app.staticTexts, labelled: "XP"), "the XP figure")
        expect(
            element(app.buttons, PRVLocator("loyalty.claimDaily", label: "Claim today's reward")),
            "the daily reward button"
        )
    }

    func testClaimingTheDailyRewardIsAOneShotPerDay() {
        launch(as: .client)
        selectTab(PRVElement.tabWallet)
        tap(anyElement(PRVElement.walletBalanceCard), "the balance card")

        let claim = element(
            app.buttons,
            PRVLocator("loyalty.claimDaily", label: "Claim today's reward")
        )
        tap(claim, "the daily reward button")

        // The backend is idempotent per day, and the UI has to say so rather
        // than offering a second claim that quietly does nothing. The button
        // keeps its identifier and flips its label, so the label is what has to
        // be waited on — matching the identifier alone would only re-assert
        // that the button is still on screen.
        expect(
            element(app.buttons, identified: "loyalty.claimDaily", labelled: "Already claimed today"),
            "the claimed state"
        )
    }
}
