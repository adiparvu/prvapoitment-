import Foundation
import XCTest

// Shared machinery for the end-to-end suites.
//
// Every test drives the shipping app against its demo (in-memory) backend,
// launched with the `-PRVDemoPersona` argument `App/Sources/PRVBeautyApp.swift`
// already reads through `UserDefaults`. Nothing here reaches the network, and
// nothing here imports a feature module: these are black-box tests of the
// product, addressed the way an assistive technology addresses it.

/// Which persona a demo launch adopts.
///
/// Mirrors `DemoPersona` in the app target. It is duplicated rather than
/// imported because a UI test target runs out-of-process and must not link the
/// app's modules.
enum PRVDemoPersona: String {
    /// No session: the welcome screen and guest browsing.
    case signedOut
    /// The premium client, opening the client tab bar.
    case client
    /// The salon owner, opening the business tab bar.
    case owner
}

/// How to find one element: by accessibility identifier first, by visible
/// label second.
///
/// The identifier is the contract — it survives copy changes, localization,
/// and layout rewrites. The label is a bridge: the screens listed in this
/// suite's notes do not carry identifiers yet, and a UI test that cannot run
/// until someone else lands a change is a UI test nobody runs. Once the
/// identifiers exist, every lookup here resolves on the first branch and the
/// labels become dead weight that can be deleted.
struct PRVLocator {
    /// Accessibility identifier the element should carry.
    let identifier: String
    /// A distinctive substring of the element's accessibility label.
    let label: String?

    /// Creates a locator.
    init(_ identifier: String, label: String? = nil) {
        self.identifier = identifier
        self.label = label
    }
}

/// Every accessibility identifier this suite addresses.
///
/// This enum is the single source of truth for the identifiers the feature
/// modules must expose; the suite's notes list the same set with the view that
/// owns each one.
enum PRVElement {
    // Welcome and guest gate
    static let welcomeRoot = PRVLocator("welcome.root", label: "PRV Beauty")
    static let continueAsGuest = PRVLocator("welcome.continueAsGuest", label: "Continue as guest")
    static let guestSheet = PRVLocator("guestSheet.root", label: "Browse as a Guest")
    static let guestStartBrowsing = PRVLocator("guestSheet.startBrowsing", label: "Start Browsing")
    static let guestSignInInstead = PRVLocator("guestSheet.signInInstead", label: "I'll sign in instead")
    static let guestLockedBooking = PRVLocator("guestSheet.locked.booking", label: "Book appointments")
    static let guestLockedRewards = PRVLocator("guestSheet.locked.rewards", label: "Earn loyalty rewards")
    static let shellSignIn = PRVLocator("shell.signIn", label: "Sign In")

    // Tabs
    static let tabHome = PRVLocator("tab.home", label: "Home")
    static let tabDiscover = PRVLocator("tab.discover", label: "Discover")
    static let tabBookings = PRVLocator("tab.appointments", label: "Bookings")
    static let tabChat = PRVLocator("tab.chat", label: "Chat")
    static let tabWallet = PRVLocator("tab.wallet", label: "Wallet")
    static let tabDashboard = PRVLocator("tab.dashboard", label: "Dashboard")
    static let tabCalendar = PRVLocator("tab.calendar", label: "Calendar")

    // Discover
    static let discoverSearchField = PRVLocator("discover.searchField", label: "Try")
    static let discoverResultCount = PRVLocator("discover.resultCount", label: "results")
    static let discoverSalonCard = PRVLocator("discover.salonCard", label: nil)
    static let discoverFiltersChip = PRVLocator("discover.filtersChip", label: "Filters")
    static let discoverVerifiedChip = PRVLocator("discover.verifiedChip", label: "Verified")
    static let discoverEmptyState = PRVLocator("discover.emptyState", label: "No matches")
    static let discoverClearFilters = PRVLocator("discover.clearFilters", label: "Clear Filters")
    static let discoverMapToggle = PRVLocator("discover.mapToggle", label: "Show results on map")
    static let discoverListToggle = PRVLocator("discover.listToggle", label: "Show results as list")

    // Salon profile
    static let salonBookNow = PRVLocator("salonProfile.bookNow", label: "Book at")

    // Booking flow
    static let bookingServiceRow = PRVLocator("booking.serviceRow", label: nil)
    static let bookingSlot = PRVLocator("booking.slot", label: nil)
    /// Date-strip cells are identified per calendar day, so a test never has
    /// to guess an index into a strip whose first day differs per screen.
    static let bookingDayCellPrefix = "booking.dayCell"
    static let bookingPrimaryAction = PRVLocator("booking.primaryAction", label: nil)
    static let bookingConfirmation = PRVLocator("booking.confirmation", label: "You're booked")
    static let bookingViewMyBookings = PRVLocator("booking.viewMyBookings", label: "View my bookings")

    // Bookings list
    static let appointmentRow = PRVLocator("appointments.row", label: nil)

    // Business
    static let dashboardTimelineRow = PRVLocator("dashboard.timelineRow", label: nil)
    static let dashboardAdvanceStatus = PRVLocator("dashboard.advanceStatus", label: nil)
    static let dashboardStatusPill = PRVLocator("dashboard.statusPill", label: "Status:")
    static let dashboardEmptyTimeline = PRVLocator("dashboard.emptyTimeline", label: "A clear day")
    static let scheduleRow = PRVLocator("schedule.row", label: nil)
    static let scheduleDayCellPrefix = "schedule.dayCell"

    // Wallet and loyalty
    static let walletBalanceCard = PRVLocator("wallet.balanceCard", label: "Beauty Wallet")
    static let walletGuestState = PRVLocator("wallet.guestState", label: "Your wallet is waiting")
    static let walletTransactionsHeader = PRVLocator("wallet.transactionsHeader", label: "Activity")
    static let loyaltyTierHero = PRVLocator("loyalty.tierHero", label: "Member")
    static let loyaltyGuestState = PRVLocator("loyalty.guestState", label: "Start earning")
    static let chatGuestState = PRVLocator("chat.guestState", label: "Sign in to message")
}

/// Base class: one launched app per test, addressed through ``PRVLocator``.
class PRVUITestCase: XCTestCase {
    /// How long to wait for a screen to settle.
    static let defaultTimeout: TimeInterval = 12

    /// How long to wait for an identifier before falling back to a label.
    /// Short on purpose — the fallback path is the slow one, and it disappears
    /// once the identifiers land.
    static let identifierProbeTimeout: TimeInterval = 2

    /// The app under test.
    private(set) var app = XCUIApplication()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try super.tearDownWithError()
    }

    // MARK: - Launching

    /// Launches the app as `persona` and waits until it is running.
    /// - Parameters:
    ///   - persona: Which demo session to cold-launch into.
    ///   - extraArguments: Additional launch arguments, e.g. a demo seed.
    @discardableResult
    func launch(
        as persona: PRVDemoPersona,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        app.launchArguments += ["-PRVDemoPersona", persona.rawValue]
        app.launchArguments += extraArguments
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Self.defaultTimeout),
            "The app did not reach the foreground."
        )
        return app
    }

    // MARK: - Finding elements

    /// Resolves an element, preferring its accessibility identifier.
    /// - Parameters:
    ///   - query: The element type to search, e.g. `app.buttons`.
    ///   - locator: Identifier plus optional label fallback.
    ///   - index: Which match to take when several share the identifier.
    ///     Ignored on the label fallback, where a label is expected to be
    ///     distinctive enough to identify one element on its own.
    func element(
        _ query: XCUIElementQuery,
        _ locator: PRVLocator,
        index: Int = 0
    ) -> XCUIElement {
        let byIdentifier = query.matching(identifier: locator.identifier)
        if byIdentifier.count > index {
            return byIdentifier.element(boundBy: index)
        }
        if byIdentifier.element(boundBy: index).waitForExistence(timeout: Self.identifierProbeTimeout) {
            return byIdentifier.element(boundBy: index)
        }
        guard let label = locator.label else {
            return byIdentifier.element(boundBy: index)
        }
        return query.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
    }

    /// The first element whose label contains `text`.
    func element(_ query: XCUIElementQuery, labelled text: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Resolves an element of unknown type.
    ///
    /// Views built with `.accessibilityElement(children: .combine)` — which is
    /// most of this app's cards and rows — surface as an element whose type
    /// depends on what was combined, so the type-specific queries cannot be
    /// used to find them.
    func anyElement(_ locator: PRVLocator) -> XCUIElement {
        let all = app.descendants(matching: .any)
        let byIdentifier = all.matching(identifier: locator.identifier).firstMatch
        if byIdentifier.waitForExistence(timeout: Self.identifierProbeTimeout) {
            return byIdentifier
        }
        guard let label = locator.label else { return byIdentifier }
        return all.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
    }

    /// How many elements currently match a locator's identifier, falling back
    /// to its label.
    func count(_ query: XCUIElementQuery, _ locator: PRVLocator) -> Int {
        let byIdentifier = query.matching(identifier: locator.identifier).count
        guard byIdentifier == 0, let label = locator.label else { return byIdentifier }
        return query.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).count
    }

    // MARK: - Assertions and interaction

    /// Waits for an element and fails the test with a readable message if it
    /// never appears.
    @discardableResult
    func expect(
        _ element: XCUIElement,
        _ description: String,
        timeout: TimeInterval = PRVUITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected \(description) to appear.",
            file: file,
            line: line
        )
        return element
    }

    /// Waits for an element, then taps it.
    func tap(
        _ element: XCUIElement,
        _ description: String,
        timeout: TimeInterval = PRVUITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        expect(element, description, timeout: timeout, file: file, line: line)
        // A cell can exist while still off-screen; tapping the coordinate of a
        // non-hittable element is the standard way through a lazy stack.
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Selects a tab in whichever experience is on screen.
    func selectTab(_ locator: PRVLocator, file: StaticString = #filePath, line: UInt = #line) {
        let tab = element(app.tabBars.buttons, locator)
        if tab.waitForExistence(timeout: Self.defaultTimeout) {
            tab.tap()
            return
        }
        // The Liquid Glass tab bar is reported as a plain button on some
        // configurations; fall back to the app-wide button query.
        let fallback = element(app.buttons, locator)
        XCTAssertTrue(
            fallback.waitForExistence(timeout: Self.defaultTimeout),
            "Expected the \(locator.identifier) tab to exist.",
            file: file,
            line: line
        )
        fallback.tap()
    }

    /// The accessibility label `PRVDateStrip` renders for a day, so a date cell
    /// can be found before the strip carries identifiers.
    func dayCellLabel(daysFromNow days: Int) -> String {
        day(daysFromNow: days).formatted(date: .complete, time: .omitted)
    }

    /// Locates one cell of a date strip.
    ///
    /// Strips start on different days per screen — the booking flow opens on
    /// today, the salon day book opens a week back — so cells are addressed by
    /// the calendar day they represent, never by position.
    /// - Parameters:
    ///   - prefix: Identifier prefix, e.g. ``PRVElement/bookingDayCellPrefix``.
    ///   - days: Offset from today.
    func dayCell(_ prefix: String, daysFromNow days: Int) -> PRVLocator {
        PRVLocator(
            "\(prefix).\(isoDay(daysFromNow: days))",
            label: dayCellLabel(daysFromNow: days)
        )
    }

    /// The `yyyy-MM-dd` suffix a date-strip cell's identifier carries.
    func isoDay(daysFromNow days: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day(daysFromNow: days))
    }

    /// A whole number of days from now, in the device's calendar.
    private func day(daysFromNow days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
    }
}
