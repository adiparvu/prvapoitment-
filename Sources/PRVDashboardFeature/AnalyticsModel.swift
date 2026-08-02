import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model behind ``AnalyticsView``.
///
/// Owns the metric selection, the reporting range (quick presets or a custom
/// range picked with graphical date pickers), the snapshot pair that produces
/// the period-over-period comparison, and the two export artefacts handed to
/// `ShareLink`.
@Observable
@MainActor
final class AnalyticsModel {
    // MARK: Inputs

    /// The measure being plotted.
    var metric: AnalyticsMetric = .revenue

    /// The quick range, or `.custom` when the date pickers drive the window.
    /// Set it through ``select(preset:)`` so the custom dates stay in step.
    private(set) var preset: AnalyticsRangePreset = .month

    /// First day of a custom range (start of day).
    var customStart: Date
    /// Last day of a custom range, inclusive (start of day).
    var customEnd: Date

    // MARK: State

    private(set) var phase: DashboardPhase = .loading
    private(set) var snapshot: DashboardSnapshot?
    private(set) var previousSnapshot: DashboardSnapshot?
    private(set) var salon: Salon?
    private(set) var hasLoadedOnce = false

    /// Prepared export artefacts, surfaced as `ShareLink` items once ready.
    private(set) var csvFileURL: URL?
    private(set) var pdfFileURL: URL?

    var toast: PRVToast?

    init(now: Date = .now) {
        let today = now.startOfDay()
        self.customEnd = today
        self.customStart = today.adding(days: -29)
    }

    // MARK: Selection

    /// Applies a quick range, snapping the custom dates to match so switching
    /// to `.custom` continues from what the user was already looking at.
    func select(preset newValue: AnalyticsRangePreset, now: Date = .now) {
        preset = newValue
        guard let days = newValue.dayCount else { return }
        let today = now.startOfDay()
        customEnd = today
        customStart = today.adding(days: -(days - 1))
    }

    /// Applies a custom window picked with the graphical date pickers.
    func applyCustomRange(start: Date, end: Date) {
        preset = .custom
        customStart = min(start, end).startOfDay()
        customEnd = max(start, end).startOfDay()
    }

    // MARK: Derived

    var currency: Currency { salon?.currency ?? .eur }

    /// The window every figure on the screen is computed over.
    /// Ranges are half-open: `[start of first day, start of the day after the
    /// last)`, matching the analytics contract.
    var range: DateInterval {
        let start = min(customStart, customEnd).startOfDay()
        let end = max(customStart, customEnd).startOfDay().adding(days: 1)
        return DateInterval(start: start, end: end)
    }

    /// The equally sized window immediately before ``range``.
    var previousRange: DateInterval {
        let current = range
        let days = max(1, Calendar.current.dateComponents([.day], from: current.start, to: current.end).day ?? 1)
        let start = current.start.adding(days: -days)
        return DateInterval(start: start, end: current.start)
    }

    var rangeTitle: String { DashboardFormat.rangeTitle(range) }

    /// Number of days in the window, inclusive.
    var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 1)
    }

    /// The plotted series for the selected metric.
    var series: [MetricPoint] {
        guard let snapshot else { return [] }
        return metric.series(for: snapshot)
    }

    /// The same series for the previous window, used by the comparison chart.
    var previousSeries: [MetricPoint] {
        guard let previousSnapshot else { return [] }
        return metric.series(for: previousSnapshot)
    }

    /// Pre-formatted headline value for the selected metric.
    var headline: String {
        guard let snapshot else { return "—" }
        return metric.headline(for: snapshot, currency: currency)
    }

    /// Movement of the selected metric against the previous window.
    var headlineDelta: MetricDelta? {
        guard let snapshot else { return nil }
        let current = metric.total(for: snapshot)
        let previous = previousSnapshot.map { metric.total(for: $0) }
        return metric.isRate
            ? DashboardMetrics.pointsDelta(current: current, previous: previous)
            : DashboardMetrics.relativeDelta(current: current, previous: previous)
    }

    /// The exact previous-period raw value, for the comparison chart.
    var previousTotal: Double? {
        previousSnapshot.map { metric.total(for: $0) }
    }

    /// The exact current raw value, for the comparison chart.
    var currentTotal: Double {
        snapshot.map { metric.total(for: $0) } ?? 0
    }

    /// The exact previous-period value, formatted.
    var previousHeadline: String? {
        guard let previousSnapshot else { return nil }
        return metric.headline(for: previousSnapshot, currency: currency)
    }

    /// The modelled cohort retention grid.
    var cohorts: [RetentionCohort] {
        guard let snapshot else { return [] }
        return RetentionModel.cohorts(for: snapshot)
    }

    /// Longest cohort row, so the grid can size its columns once.
    var cohortColumnCount: Int {
        cohorts.map(\.retention.count).max() ?? 0
    }

    /// Name used in export filenames and the PDF header.
    var salonName: String { salon?.name ?? "PRV Beauty" }

    // MARK: Loading

    /// Loads the window and its comparison window concurrently.
    func load(salonID: Salon.ID, using deps: PRVDependencies) async {
        if !hasLoadedOnce { phase = .loading }

        let window = range
        let previousWindow = previousRange

        async let currentTask = deps.analytics.dashboard(
            salonID: salonID,
            periodStart: window.start,
            periodEnd: window.end
        )
        async let previousTask = deps.analytics.dashboard(
            salonID: salonID,
            periodStart: previousWindow.start,
            periodEnd: previousWindow.end
        )
        async let salonTask = deps.salons.salon(id: salonID)

        salon = try? await salonTask

        do {
            snapshot = try await currentTask
            previousSnapshot = try? await previousTask
            phase = .loaded
        } catch {
            previousSnapshot = nil
            phase = .failed(DashboardCopy.friendlyMessage(for: error))
        }

        // A changed window invalidates anything already exported.
        csvFileURL = nil
        pdfFileURL = nil
        hasLoadedOnce = true
    }

    // MARK: Exports

    /// Writes the current series to a CSV file in the temporary directory and
    /// exposes it for sharing.
    func exportCSV() {
        guard let snapshot else { return }
        let text = AnalyticsExport.csvText(
            metric: metric,
            snapshot: snapshot,
            series: series,
            salonName: salonName,
            currency: currency
        )
        do {
            csvFileURL = try AnalyticsExport.write(
                text,
                fileName: AnalyticsExport.fileName(salonName: salonName, metric: metric, range: range, fileExtension: "csv")
            )
            PRVHaptics.success()
            toast = .success("CSV ready to share")
        } catch {
            PRVHaptics.error()
            toast = .error("We couldn't build the CSV. Try again in a moment.")
        }
    }

    /// Records a rendered PDF (or the failure to render one).
    /// The rendering itself lives in the view layer because it needs a `View`.
    func attachPDF(_ url: URL?) {
        guard let url else {
            PRVHaptics.error()
            toast = .error("We couldn't build the PDF. Try again in a moment.")
            return
        }
        pdfFileURL = url
        PRVHaptics.success()
        toast = .success("PDF report ready to share")
    }

    /// Suggested filename for the PDF artefact.
    var pdfFileName: String {
        AnalyticsExport.fileName(salonName: salonName, metric: metric, range: range, fileExtension: "pdf")
    }
}
