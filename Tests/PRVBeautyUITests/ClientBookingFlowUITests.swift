import XCTest

/// The flagship journey, end to end: a signed-in client finds a salon, picks a
/// treatment, and walks the four-step booking flow to a confirmed appointment
/// that then shows up in their bookings.
final class ClientBookingFlowUITests: PRVUITestCase {
    /// The step titles the flow's primary button carries, in order.
    private enum Step {
        static let toArtist = "Choose Your Artist"
        static let toTime = "Pick a Time"
        static let toReview = "Review & Pay"
        static let confirm = "Confirm Booking"
    }

    /// Cut & Blow-Dry is chosen deliberately: it is the demo salon's one
    /// treatment that does **not** require a deposit, so confirming lands on
    /// the confirmation seal instead of opening checkout over it. Prepayment
    /// has its own flow and its own test surface.
    private let treatment = "Cut & Blow-Dry"

    func testClientBooksAnAppointmentThroughTheFourStepFlow() {
        launch(as: .client)

        openSalonProfile()
        selectTreatmentAndStartBooking()

        // Step 1 — Services. The treatment came in pre-selected from the
        // profile, so the flow can advance immediately.
        expect(app.navigationBars["Choose Services"], "the services step")
        tapPrimaryAction(Step.toArtist)

        // Step 2 — Artist. "Any available artist" is a valid choice, so this
        // step is always satisfied.
        expect(app.navigationBars[Step.toArtist], "the artist step")
        tapPrimaryAction(Step.toTime)

        // Step 3 — Time.
        expect(app.navigationBars[Step.toTime], "the time step")
        chooseTomorrow()
        chooseFirstSlot()
        tapPrimaryAction(Step.toReview)

        // Step 4 — Review & pay.
        expect(app.navigationBars[Step.toReview], "the review step")
        tapPrimaryAction(Step.confirm)

        // Confirmation.
        // The seal combines its headline and subtitle into one element.
        expect(anyElement(PRVElement.bookingConfirmation), "the confirmation seal", timeout: 20)

        tap(
            element(app.buttons, PRVElement.bookingViewMyBookings),
            "the confirmation's bookings link"
        )

        // …and the appointment is really there.
        expect(app.navigationBars["Bookings"], "the bookings list")
        expect(
            element(app.staticTexts, labelled: treatment),
            "the newly booked treatment in the bookings list"
        )
    }

    /// The flow is navigable in both directions: a client who changes their
    /// mind must not have to abandon the booking.
    func testTheFlowCanBeSteppedBackwards() {
        launch(as: .client)
        openSalonProfile()
        selectTreatmentAndStartBooking()

        tapPrimaryAction(Step.toArtist)
        expect(app.navigationBars[Step.toArtist], "the artist step")

        let back = element(app.buttons, PRVLocator("booking.backAction", label: "Back to Services"))
        tap(back, "the back control")

        expect(app.navigationBars["Choose Services"], "the services step again")
    }

    /// Deselecting every treatment must disable the way forward rather than
    /// letting an empty booking through.
    func testTheFlowRefusesToAdvanceWithNoTreatment() {
        launch(as: .client)
        openSalonProfile()
        selectTreatmentAndStartBooking()

        // Remove the pre-selected treatment.
        tap(serviceRow(), "the selected treatment row")

        let primary = element(app.buttons, PRVLocator("booking.primaryAction", label: Step.toArtist))
        expect(primary, "the primary action")
        XCTAssertFalse(primary.isEnabled, "An empty booking must not be able to advance.")
    }

    // MARK: - Steps

    /// Discover → the demo salon's profile.
    private func openSalonProfile() {
        selectTab(PRVElement.tabDiscover)
        expect(app.navigationBars["Discover"], "the Discover screen")
        tap(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the Maison Lumière result"
        )
    }

    /// Picks the treatment on the profile, then opens the booking flow.
    ///
    /// Selecting first is what makes the booking bar's label unambiguous — it
    /// changes from "Book at …" (which the result card also uses) to
    /// "Book 1 service · …".
    private func selectTreatmentAndStartBooking() {
        tap(element(app.buttons, labelled: treatment), "the \(treatment) row")
        tap(element(app.buttons, labelled: "Book 1 service"), "the Book Now bar")
    }

    /// The flow's primary button for the current step.
    private func tapPrimaryAction(_ title: String) {
        tap(
            element(app.buttons, PRVLocator("booking.primaryAction", label: title)),
            "the \(title) button"
        )
    }

    /// A service row in the booking flow's first step.
    private func serviceRow() -> XCUIElement {
        element(app.buttons, PRVLocator(PRVElement.bookingServiceRow.identifier, label: treatment))
    }

    /// Moves the date strip to tomorrow.
    ///
    /// Today is not a safe default: a run late in the afternoon has few or no
    /// bookable times left, and the availability engine correctly returns an
    /// empty board. Tomorrow always has a full day of slots.
    private func chooseTomorrow() {
        let tomorrow = element(
            app.buttons,
            dayCell(PRVElement.bookingDayCellPrefix, daysFromNow: 1)
        )
        tap(tomorrow, "tomorrow in the date strip")
    }

    /// Chooses the first bookable time on the selected day.
    private func chooseFirstSlot() {
        // Without identifiers, the "Recommended" row is the only slot pill with
        // a predictable label; a plain pill reads as a localized clock time.
        let slot = element(
            app.buttons,
            PRVLocator(PRVElement.bookingSlot.identifier, label: "Recommended,")
        )
        tap(slot, "a bookable time")
    }
}
