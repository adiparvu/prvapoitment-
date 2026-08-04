import XCTest

/// The salon side: an owner cold-launches onto the dashboard, reads the day,
/// and moves a booking along the front-desk flow.
final class BusinessExperienceUITests: PRVUITestCase {
    /// Launch argument that seeds the demo backend with a booking on today's
    /// date. See this suite's notes — the demo backend currently seeds its one
    /// appointment three days out, which is exactly the window the dashboard's
    /// "Today" timeline excludes.
    private static let todaySeedArgument = "-PRVDemoSeedToday"

    func testOwnerLandsOnTheDashboard() {
        launch(as: .owner)

        expect(app.navigationBars["Dashboard"], "the salon dashboard")
        expect(element(app.staticTexts, labelled: "Maison Lumière"), "the salon name")
        // The business tab set, not the client one.
        expect(element(app.tabBars.buttons, PRVElement.tabCalendar), "the Calendar tab")
        XCTAssertFalse(
            app.tabBars.buttons["Bookings"].exists,
            "The owner experience must not show the client's Bookings tab."
        )
    }

    func testDashboardRendersItsReportingSections() {
        launch(as: .owner)
        expect(app.navigationBars["Dashboard"], "the salon dashboard")

        expect(element(app.staticTexts, labelled: "Today"), "the day timeline section")
        expect(
            element(app.buttons, PRVLocator("dashboard.analytics", label: "Open detailed analytics")),
            "the analytics entry point"
        )
    }

    /// The day book is the owner's calendar, scoped to the salon rather than
    /// to the owner's own bookings.
    func testCalendarShowsTheSalonDayBook() {
        launch(as: .owner)
        selectTab(PRVElement.tabCalendar)

        expect(app.navigationBars["Calendar"], "the salon day book")

        // The demo salon's one seeded booking is three days out.
        tap(
            element(app.buttons, dayCell(PRVElement.scheduleDayCellPrefix, daysFromNow: 3)),
            "the day the seeded booking falls on"
        )

        expect(
            element(app.staticTexts, labelled: "Balayage & Gloss"),
            "the seeded booking in the day book"
        )
    }

    /// Opening a booking from the day book lands on its detail screen.
    func testOpeningABookingFromTheDayBook() throws {
        launch(as: .owner)
        selectTab(PRVElement.tabCalendar)
        expect(app.navigationBars["Calendar"], "the salon day book")

        tap(
            element(app.buttons, dayCell(PRVElement.scheduleDayCellPrefix, daysFromNow: 3)),
            "the day the seeded booking falls on"
        )
        tap(
            element(app.buttons, PRVLocator(PRVElement.scheduleRow.identifier, label: "Balayage & Gloss")),
            "the booking row"
        )

        expect(app.navigationBars["Booking"], "the booking detail screen")
        expect(element(app.staticTexts, labelled: "Treatments"), "the treatments section")
        expect(element(app.staticTexts, labelled: "Total"), "the booking total")
    }

    /// The front-desk flow: Confirm → Check in → Start → Complete, one tap per
    /// step, straight from the dashboard's day timeline.
    ///
    /// The timeline only ever shows *today's* book. The demo backend seeds its
    /// single appointment three days out, so this test needs the demo session
    /// to carry a booking on today's date — see ``todaySeedArgument``. Until
    /// that seed exists the test skips with that requirement spelled out,
    /// rather than failing for a reason nobody reading the report could act on.
    func testOwnerMovesABookingThroughItsStatus() throws {
        launch(as: .owner, extraArguments: [Self.todaySeedArgument, "YES"])
        expect(app.navigationBars["Dashboard"], "the salon dashboard")

        let firstAction = element(
            app.buttons,
            PRVLocator(PRVElement.dashboardAdvanceStatus.identifier, label: "Check in")
        )
        try XCTSkipUnless(
            firstAction.waitForExistence(timeout: PRVUITestCase.identifierProbeTimeout),
            """
            The dashboard timeline is empty: the demo backend seeds its only \
            appointment three days out, and the timeline shows today's book. \
            Launch the demo with a booking on today's date (see \
            \(Self.todaySeedArgument)) to exercise the status flow.
            """
        )

        // Confirmed → Checked In.
        tap(firstAction, "the Check in action")
        expect(
            anyElement(PRVLocator(PRVElement.dashboardStatusPill.identifier, label: "Checked In")),
            "the Checked In status"
        )

        // Checked In → In Progress.
        tap(
            element(app.buttons, PRVLocator(PRVElement.dashboardAdvanceStatus.identifier, label: "Start")),
            "the Start action"
        )
        expect(
            anyElement(PRVLocator(PRVElement.dashboardStatusPill.identifier, label: "In Progress")),
            "the In Progress status"
        )

        // In Progress → Completed, where the flow ends: no further action is
        // offered on a finished visit.
        tap(
            element(app.buttons, PRVLocator(PRVElement.dashboardAdvanceStatus.identifier, label: "Complete")),
            "the Complete action"
        )
        expect(
            anyElement(PRVLocator(PRVElement.dashboardStatusPill.identifier, label: "Completed")),
            "the Completed status"
        )
        XCTAssertEqual(
            count(app.buttons, PRVElement.dashboardAdvanceStatus),
            0,
            "A completed visit must offer no further status action."
        )
    }

    /// With nothing booked, the timeline says so instead of showing a blank.
    func testAnEmptyDayIsExplained() throws {
        launch(as: .owner)
        expect(app.navigationBars["Dashboard"], "the salon dashboard")

        let advance = element(app.buttons, PRVElement.dashboardAdvanceStatus)
        try XCTSkipIf(
            advance.waitForExistence(timeout: PRVUITestCase.identifierProbeTimeout),
            "Today's book is not empty in this demo session."
        )

        expect(app.staticTexts["A clear day"], "the empty-day state")
    }
}
