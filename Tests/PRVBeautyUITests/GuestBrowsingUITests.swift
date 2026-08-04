import XCTest

/// The unauthenticated experience: a visitor must be able to reach the product
/// from the welcome screen, see exactly what a free account unlocks, browse,
/// and get back to signing in — without ever hitting a dead end.
final class GuestBrowsingUITests: PRVUITestCase {
    /// A cold launch with no persona stops on the welcome surface.
    func testWelcomeScreenIsTheDefaultColdLaunch() {
        launch(as: .signedOut)

        // The hero combines its two lines into one accessibility element, so
        // it is addressed by a substring rather than an exact label.
        expect(anyElement(PRVElement.welcomeRoot), "the welcome hero")
        expect(
            element(app.buttons, PRVElement.continueAsGuest),
            "the guest entry point"
        )
        expect(app.buttons["Sign in with Apple"], "the Apple sign-in button")
    }

    /// The guest sheet is the app's honesty screen: it says what is locked
    /// *before* the visitor invests any time.
    func testGuestSheetSpellsOutWhatIsLocked() {
        launch(as: .signedOut)

        tap(element(app.buttons, PRVElement.continueAsGuest), "Continue as guest")

        expect(anyElement(PRVElement.guestSheet), "the guest limits sheet")
        expect(anyElement(PRVElement.guestLockedBooking), "the locked booking row")
        expect(anyElement(PRVElement.guestLockedRewards), "the locked rewards row")
        expect(
            element(app.buttons, PRVElement.guestStartBrowsing),
            "the Start Browsing button"
        )
    }

    /// Choosing to browse hands control to the client shell, signed out.
    func testStartingToBrowseOpensTheClientShell() {
        launch(as: .signedOut)

        tap(element(app.buttons, PRVElement.continueAsGuest), "Continue as guest")
        tap(element(app.buttons, PRVElement.guestStartBrowsing), "Start Browsing")

        selectTab(PRVElement.tabDiscover)
        expect(app.navigationBars["Discover"], "the Discover screen")
        // Discover is the one tab a guest can act on, so it must show real
        // inventory rather than an empty state.
        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "a bookable salon result"
        )
    }

    /// Personal tabs explain themselves instead of looking broken.
    func testPersonalTabsShowLockedStatesForGuests() {
        launch(as: .signedOut)
        tap(element(app.buttons, PRVElement.continueAsGuest), "Continue as guest")
        tap(element(app.buttons, PRVElement.guestStartBrowsing), "Start Browsing")

        selectTab(PRVElement.tabWallet)
        expect(app.staticTexts["Your wallet is waiting"], "the wallet's guest state")

        selectTab(PRVElement.tabChat)
        expect(app.staticTexts["Sign in to message"], "the chat guest state")
    }

    /// The shell's pinned Sign In is a guest's only way back to the gate, so
    /// it has to be there and it has to work.
    func testGuestsCanReturnToTheWelcomeScreen() {
        launch(as: .signedOut)
        tap(element(app.buttons, PRVElement.continueAsGuest), "Continue as guest")
        tap(element(app.buttons, PRVElement.guestStartBrowsing), "Start Browsing")

        tap(element(app.buttons, PRVElement.shellSignIn), "the shell's Sign In button")

        expect(anyElement(PRVElement.welcomeRoot), "the welcome hero again")
    }

    /// Backing out of the guest sheet keeps the visitor on the gate.
    func testDecliningTheGuestSheetKeepsTheGateUp() {
        launch(as: .signedOut)

        tap(element(app.buttons, PRVElement.continueAsGuest), "Continue as guest")
        tap(element(app.buttons, PRVElement.guestSignInInstead), "I'll sign in instead")

        expect(app.buttons["Sign in with Apple"], "the sign-in card")
    }
}
