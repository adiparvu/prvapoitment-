import Foundation
import XCTest

/// Startup is a product requirement, not a nice-to-have: the brief asks for a
/// sub-second cold launch, and a launch budget only holds if something measures
/// it on every run.
///
/// Two complementary things are measured here:
///
/// * ``testColdLaunchPerformance`` records `XCTApplicationLaunchMetric`, which
///   is the only measurement that isolates the app's own launch from the test
///   harness. Its baseline lives in the Xcode result bundle — set it to the
///   sub-second target once, and any regression fails the run.
/// * ``testWelcomeScreenIsInteractiveWithinTheBudget`` asserts a wall-clock
///   ceiling in the test itself, so a regression is caught even on a machine
///   with no stored baseline (a fresh CI runner, a new developer's checkout).
final class LaunchPerformanceTests: XCTestCase {
    /// Wall-clock ceiling from `launch()` to the first interactive element.
    ///
    /// This is deliberately *not* the sub-second product budget. It includes
    /// the whole harness round trip — springboard, process spawn, the test
    /// runner attaching, and the accessibility hierarchy being served — which
    /// costs multiple seconds before a single line of app code runs. The
    /// product budget is enforced by the launch metric above; this number is a
    /// regression tripwire for the end-to-end experience.
    static let interactiveBudget: TimeInterval = 5

    /// How many launches the metric averages over.
    private static let iterations = 5

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    func testColdLaunchPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations

        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            let app = XCUIApplication()
            // The signed-out persona is the true cold-launch path: no session
            // to restore, and the welcome surface is what a first-time user
            // waits for.
            app.launchArguments = ["-PRVDemoPersona", PRVDemoPersona.signedOut.rawValue]
            app.launch()
        }
    }

    func testWelcomeScreenIsInteractiveWithinTheBudget() {
        let app = XCUIApplication()
        app.launchArguments = ["-PRVDemoPersona", PRVDemoPersona.signedOut.rawValue]

        let started = Date.now
        app.launch()
        // The welcome hero combines its lines into one accessibility element,
        // so it is matched on a substring of that combined label.
        let hero = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "PRV Beauty"))
            .firstMatch
        XCTAssertTrue(
            hero.waitForExistence(timeout: Self.interactiveBudget * 2),
            "The welcome screen never appeared."
        )
        let elapsed = Date.now.timeIntervalSince(started)
        app.terminate()

        XCTAssertLessThan(
            elapsed,
            Self.interactiveBudget,
            "Cold launch to an interactive welcome screen took \(String(format: "%.2f", elapsed)) s."
        )
    }

    /// A signed-in launch does more work — it restores a session and builds the
    /// tab bar — so it gets its own baseline rather than hiding inside the
    /// signed-out number.
    func testSignedInLaunchPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations

        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["-PRVDemoPersona", PRVDemoPersona.client.rawValue]
            app.launch()
        }
    }
}
