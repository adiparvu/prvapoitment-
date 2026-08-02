import Foundation
import PRVFoundation
import PRVModels

// MARK: - Metric

/// The measures the analytics screen can plot.
///
/// Revenue is the only measure the analytics contract exposes as a real daily
/// series. Counts are distributed across days by each day's revenue weight, and
/// rates are shaped by the same weighting around their exact period value — the
/// UI states this next to every derived chart so nobody mistakes a modelled
/// shape for per-day telemetry.
enum AnalyticsMetric: String, CaseIterable, Hashable, Sendable, Identifiable {
    case revenue
    case bookings
    case retention
    case averageTicket
    case conversion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .revenue: "Revenue"
        case .bookings: "Bookings"
        case .retention: "Retention"
        case .averageTicket: "Average ticket"
        case .conversion: "Conversion"
        }
    }

    var symbolName: String {
        switch self {
        case .revenue: "eurosign.circle"
        case .bookings: "calendar"
        case .retention: "arrow.triangle.2.circlepath"
        case .averageTicket: "creditcard"
        case .conversion: "checkmark.circle"
        }
    }

    /// One line explaining what the number means, shown under the headline.
    var explanation: String {
        switch self {
        case .revenue: "Everything invoiced in the period, services and retail."
        case .bookings: "Appointments created in the period, whatever their outcome."
        case .retention: "Share of clients who came back within the period."
        case .averageTicket: "Average value of a completed appointment."
        case .conversion: "Share of booked appointments that were completed."
        }
    }

    /// Whether the metric is a 0…1 rate rather than a count or an amount.
    var isRate: Bool {
        switch self {
        case .retention, .conversion: true
        case .revenue, .bookings, .averageTicket: false
        }
    }

    /// Whether the metric is money.
    var isCurrency: Bool {
        switch self {
        case .revenue, .averageTicket: true
        case .bookings, .retention, .conversion: false
        }
    }

    /// Whether the daily series is derived rather than measured, which the UI
    /// discloses beneath the chart.
    var hasModelledSeries: Bool { self != .revenue }

    /// The exact period value, used for trends and the headline.
    func total(for snapshot: DashboardSnapshot) -> Double {
        switch self {
        case .revenue: snapshot.revenue.amount.doubleValue
        case .bookings: Double(snapshot.appointmentCount)
        case .retention: snapshot.retentionRate
        case .averageTicket: snapshot.averageTicket.amount.doubleValue
        case .conversion: conversionRate(for: snapshot)
        }
    }

    /// The pre-formatted headline for the period.
    func headline(for snapshot: DashboardSnapshot, currency: Currency) -> String {
        format(total(for: snapshot), currency: currency)
    }

    /// Formats a raw value in this metric's units.
    func format(_ value: Double, currency: Currency) -> String {
        switch self {
        case .revenue, .averageTicket: DashboardFormat.currency(value, currency: currency)
        case .bookings: DashboardFormat.integer(Int(value.rounded()))
        case .retention, .conversion: DashboardFormat.precisePercent(value)
        }
    }

    /// Compact formatting for chart axes.
    func axisFormat(_ value: Double, currency: Currency) -> String {
        switch self {
        case .revenue, .averageTicket: DashboardFormat.compactCurrency(value, currency: currency)
        case .bookings: DashboardFormat.integer(Int(value.rounded()))
        case .retention, .conversion: DashboardFormat.percent(value)
        }
    }

    /// The daily series plotted for this metric.
    func series(for snapshot: DashboardSnapshot) -> [MetricPoint] {
        let revenue = snapshot.revenueSeries.sorted { $0.date < $1.date }
        guard !revenue.isEmpty else { return [] }
        let weights = Self.normalizedWeights(revenue)

        switch self {
        case .revenue:
            return revenue

        case .bookings:
            let perDay = Double(snapshot.appointmentCount) / Double(revenue.count)
            return revenue.indices.map { index in
                MetricPoint(
                    date: revenue[index].date,
                    value: Decimal((perDay * weights[index]).rounded())
                )
            }

        case .averageTicket:
            let perDayBookings = Double(snapshot.appointmentCount) / Double(revenue.count)
            return revenue.indices.map { index in
                let bookings = max(1, (perDayBookings * weights[index]).rounded())
                let ticket = revenue[index].value.doubleValue / bookings
                return MetricPoint(date: revenue[index].date, value: Decimal(ticket).rounded())
            }

        case .retention:
            return Self.rateSeries(revenue, weights: weights, rate: snapshot.retentionRate)

        case .conversion:
            return Self.rateSeries(revenue, weights: weights, rate: conversionRate(for: snapshot))
        }
    }

    /// Completed over booked, guarded against an empty period.
    private func conversionRate(for snapshot: DashboardSnapshot) -> Double {
        guard snapshot.appointmentCount > 0 else { return 0 }
        return min(1, Double(snapshot.completedCount) / Double(snapshot.appointmentCount))
    }

    /// Daily revenue weights normalized to a mean of 1.
    private static func normalizedWeights(_ series: [MetricPoint]) -> [Double] {
        let values = series.map(\.value.doubleValue)
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        guard mean > 0 else { return values.map { _ in 1 } }
        return values.map { $0 / mean }
    }

    /// Shapes a period rate across days: busy days pull slightly above the
    /// period value, quiet days slightly below, and the mean stays exact.
    private static func rateSeries(
        _ series: [MetricPoint],
        weights: [Double],
        rate: Double
    ) -> [MetricPoint] {
        series.indices.map { index in
            let shaped = min(1, max(0, rate * (0.9 + 0.1 * weights[index])))
            return MetricPoint(date: series[index].date, value: Decimal(shaped))
        }
    }
}

// MARK: - Range presets

/// Quick ranges offered above the custom date pickers.
enum AnalyticsRangePreset: String, CaseIterable, Hashable, Sendable, Identifiable {
    case week
    case month
    case quarter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        case .custom: "Custom"
        }
    }

    /// Length in days, or `nil` when the range comes from the date pickers.
    var dayCount: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .custom: nil
        }
    }
}

// MARK: - Retention cohorts

/// One acquisition cohort in the retention grid: the month clients first
/// visited, how many there were, and the share still active each month after.
struct RetentionCohort: Identifiable, Hashable, Sendable {
    let start: Date
    let title: String
    let size: Int
    /// Index 0 is the acquisition month (always 1.0), index *n* is *n* months
    /// later. Older cohorts have more observed months, giving the grid its
    /// classic triangular shape.
    let retention: [Double]

    var id: Date { start }
}

/// Builds the cohort grid.
///
/// The analytics contract reports a single `retentionRate` for the window, so
/// cohorts are projected from it: each additional month applies the rate again,
/// with a small per-cohort drift so the grid reads like real data rather than
/// one repeated row. The UI labels the grid as modelled.
enum RetentionModel {
    static func cohorts(
        for snapshot: DashboardSnapshot,
        months: Int = 6,
        calendar: Calendar = .current
    ) -> [RetentionCohort] {
        guard months > 0 else { return [] }
        let components = calendar.dateComponents([.year, .month], from: snapshot.periodEnd)
        let anchor = calendar.date(from: components) ?? snapshot.periodEnd
        let rate = min(0.98, max(0.05, snapshot.retentionRate))
        let baseSize = Double(max(snapshot.newClientCount, 1))

        var cohorts: [RetentionCohort] = []
        for index in 0 ..< months {
            let monthsBack = months - 1 - index
            guard let start = calendar.date(byAdding: .month, value: -monthsBack, to: anchor) else { continue }
            let observed = monthsBack + 1
            let drift = 1 + 0.08 * Double(index - months / 2)
            let size = max(1, Int((baseSize * drift).rounded()))

            var retention: [Double] = []
            retention.reserveCapacity(observed)
            for month in 0 ..< observed {
                if month == 0 {
                    retention.append(1)
                } else {
                    let decayed = pow(rate, Double(month)) * (1 + 0.015 * Double(index - month))
                    retention.append(min(1, max(0, decayed)))
                }
            }

            cohorts.append(
                RetentionCohort(
                    start: start,
                    title: start.formatted(.dateTime.month(.abbreviated).year(.twoDigits)),
                    size: size,
                    retention: retention
                )
            )
        }
        return cohorts
    }
}
