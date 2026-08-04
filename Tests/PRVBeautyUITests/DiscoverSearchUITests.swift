import XCTest

/// Discover is the conversion path: every booking, payment, and loyalty award
/// starts with finding a salon. Search, filters, sort, and the map switch all
/// have to work for a signed-in client.
final class DiscoverSearchUITests: PRVUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launch(as: .client)
        selectTab(PRVElement.tabDiscover)
        expect(app.navigationBars["Discover"], "the Discover screen")
    }

    /// A cold Discover shows the whole demo catalogue.
    func testDiscoverListsEverySalonOnFirstLoad() {
        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the Maison Lumière result"
        )
        expect(
            element(app.buttons, labelled: "Book at Velvet Nails Studio"),
            "the Velvet Nails Studio result"
        )
    }

    /// Typing narrows the results — the search runs on a 300 ms debounce, so
    /// the assertion waits rather than sampling immediately.
    func testSearchingNarrowsTheResults() {
        let field = element(app.textFields, PRVElement.discoverSearchField)
        tap(field, "the search field")
        field.typeText("Velvet")

        expect(
            element(app.buttons, labelled: "Book at Velvet Nails Studio"),
            "the matching salon"
        )
        XCTAssertTrue(
            waitForDisappearance(of: element(app.buttons, labelled: "Book at Maison Lumière")),
            "Expected the non-matching salon to drop out of the results."
        )
    }

    /// A query nothing matches must land on the empty state, not on stale rows.
    func testAnUnmatchableQueryShowsTheEmptyState() {
        let field = element(app.textFields, PRVElement.discoverSearchField)
        tap(field, "the search field")
        field.typeText("zzzzzz")

        expect(app.staticTexts["No matches"], "the empty state")
    }

    /// Clearing the field restores the full catalogue.
    func testClearingTheSearchRestoresEveryResult() {
        let field = element(app.textFields, PRVElement.discoverSearchField)
        tap(field, "the search field")
        field.typeText("Velvet")
        expect(
            element(app.buttons, labelled: "Book at Velvet Nails Studio"),
            "the narrowed results"
        )

        tap(app.buttons["Clear search text"], "the clear button")

        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the full catalogue again"
        )
    }

    /// Category chips write straight into the `SalonSearchQuery`.
    func testCategoryFilteringNarrowsTheResults() {
        tap(element(app.buttons, labelled: "Nail Studio"), "the Nail Studio chip")

        expect(
            element(app.buttons, labelled: "Book at Velvet Nails Studio"),
            "the nail studio"
        )
        XCTAssertTrue(
            waitForDisappearance(of: element(app.buttons, labelled: "Book at Maison Lumière")),
            "Expected the hair salon to be filtered out."
        )

        // Tapping the chip again clears it.
        tap(element(app.buttons, labelled: "Nail Studio"), "the Nail Studio chip again")
        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the hair salon returning"
        )
    }

    /// The rating floor is the other one-tap filter on the bar.
    func testRatingFilterNarrowsTheResults() {
        tap(element(app.buttons, PRVLocator("discover.ratingChip", label: "4.5+")), "the 4.5+ chip")

        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the 4.9-rated salon"
        )
    }

    /// The filter sheet is the full query editor behind the quick chips.
    func testTheFilterSheetOpens() {
        tap(element(app.buttons, PRVElement.discoverFiltersChip), "the Filters chip")

        expect(
            anyElement(PRVLocator("discover.filterSheet", label: "Filters")),
            "the filter sheet"
        )
    }

    /// Sorting is the only way to change ordering, so it lives pinned in the bar.
    func testSortingByRatingPutsTheBestSalonFirst() {
        tap(
            element(app.buttons, PRVLocator("discover.sortMenu", label: "Sort by")),
            "the sort menu"
        )
        tap(element(app.buttons, labelled: "Rating"), "the Rating option")

        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the highest-rated salon"
        )
    }

    /// Map mode hides the list, so the switch back has to stay reachable.
    func testTheMapSwitchIsReversible() {
        tap(element(app.buttons, PRVElement.discoverMapToggle), "the map switch")

        let backToList = expect(
            element(app.buttons, PRVElement.discoverListToggle),
            "the switch back to the list"
        )
        backToList.tap()

        expect(
            element(app.buttons, labelled: "Book at Maison Lumière"),
            "the result list again"
        )
    }

    // MARK: - Helpers

    /// Waits for an element to go away.
    ///
    /// The expectation is built directly rather than through
    /// `XCTestCase.expectation(for:evaluatedWith:)` so it is never registered
    /// with the test case — a registered expectation that is waited on by a
    /// separate waiter is exactly the pattern that produces XCTest's
    /// "unwaited expectation" noise.
    private func waitForDisappearance(
        of element: XCUIElement,
        timeout: TimeInterval = PRVUITestCase.defaultTimeout
    ) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
