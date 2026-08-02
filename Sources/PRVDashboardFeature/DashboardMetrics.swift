import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// Pure, deterministic transforms from `DashboardSnapshot` into what the UI
// draws. Everything here is `nonisolated` and value-typed so it can run off the
// main actor, be snapshot-tested, and never touch SwiftUI.

// MARK: - Delta

/// A period-over-period movement, expressed in terms of *performance* rather
/// than raw arithmetic direction: for a metric where lower is better (a
/// cancellation rate), a fall is `.up` — an improvement — and the text says so.
///
/// The design system's `PRVStatTile.Trend` keeps its styling private, so the
/// feature carries its own delta type for headline chrome and converts where a
/// tile is involved.
struct MetricDelta: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case up
        case down
        case flat
    }

    let direction: Direction
    /// Display text, e.g. `12%`, `1.4 pts better`.
    let text: String

    var symbolName: String {
        switch direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "minus"
        }
    }

    var tint: Color {
        switch direction {
        case .up: Color.prv.success
        case .down: Color.prv.danger
        case .flat: Color.prv.textSecondary
        }
    }

    /// Sentence fragment used in VoiceOver labels.
    var spokenText: String {
        switch direction {
        case .up: "up \(text)"
        case .down: "down \(text)"
        case .flat: "no change"
        }
    }

    /// The design-system tile equivalent.
    var statTileTrend: PRVStatTile.Trend {
        switch direction {
        case .up: .up(text)
        case .down: .down(text)
        case .flat: .flat
        }
    }
}

// MARK: - KPI

/// One tile in the dashboard's KPI grid: a pre-formatted value, the movement
/// against the previous window, and a VoiceOver sentence that spells the
/// movement out in plain language.
struct DashboardKPI: Identifiable, Equatable, Sendable {
    /// Stable key so the grid animates values instead of re-creating tiles.
    let id: String
    let label: String
    let value: String
    let trend: PRVStatTile.Trend?
    let sparkline: [Double]
    /// Full sentence read by VoiceOver, replacing the tile's terser default.
    let accessibilityLabel: String
}

/// Builds the KPI grid, the forecast extension, the occupancy heatmap, and the
/// employee ranking from a snapshot pair (current window + previous window).
enum DashboardMetrics {
    /// Movement smaller than this reads as "no change" rather than noise.
    private static let flatThreshold = 0.005

    // MARK: KPI grid

    /// The six headline KPIs, in reading order.
    /// - Parameters:
    ///   - snapshot: The current window.
    ///   - previous: The equally sized window before it, when available.
    ///   - period: The selected window, used for comparison wording.
    static func kpis(
        for snapshot: DashboardSnapshot,
        previous: DashboardSnapshot?,
        period: DashboardPeriod
    ) -> [DashboardKPI] {
        let comparison = period.comparisonCaption
        let spark = snapshot.revenueSeries.map(\.value.doubleValue)

        let revenueDelta = relativeDelta(
            current: snapshot.revenue.amount.doubleValue,
            previous: previous?.revenue.amount.doubleValue
        )
        let appointmentsDelta = relativeDelta(
            current: Double(snapshot.appointmentCount),
            previous: previous.map { Double($0.appointmentCount) }
        )
        let occupancyDelta = pointsDelta(
            current: snapshot.occupancyRate,
            previous: previous?.occupancyRate
        )
        let ticketDelta = relativeDelta(
            current: snapshot.averageTicket.amount.doubleValue,
            previous: previous?.averageTicket.amount.doubleValue
        )
        let newClientsDelta = relativeDelta(
            current: Double(snapshot.newClientCount),
            previous: previous.map { Double($0.newClientCount) }
        )
        let cancellationDelta = pointsDelta(
            current: snapshot.cancellationRate,
            previous: previous?.cancellationRate,
            higherIsBetter: false
        )

        return [
            DashboardKPI(
                id: "revenue",
                label: "Revenue",
                value: DashboardFormat.compactCurrency(snapshot.revenue),
                trend: revenueDelta?.statTileTrend,
                sparkline: spark,
                accessibilityLabel: sentence(
                    "Revenue",
                    snapshot.revenue.formatted,
                    delta: revenueDelta,
                    comparison: comparison
                )
            ),
            DashboardKPI(
                id: "appointments",
                label: "Appointments",
                value: DashboardFormat.integer(snapshot.appointmentCount),
                trend: appointmentsDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Appointments",
                    "\(snapshot.appointmentCount), \(snapshot.completedCount) completed",
                    delta: appointmentsDelta,
                    comparison: comparison
                )
            ),
            DashboardKPI(
                id: "occupancy",
                label: "Occupancy",
                value: DashboardFormat.percent(snapshot.occupancyRate),
                trend: occupancyDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Chair occupancy",
                    DashboardFormat.percent(snapshot.occupancyRate),
                    delta: occupancyDelta,
                    comparison: comparison
                )
            ),
            DashboardKPI(
                id: "averageTicket",
                label: "Average ticket",
                value: DashboardFormat.compactCurrency(snapshot.averageTicket),
                trend: ticketDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Average ticket",
                    snapshot.averageTicket.formatted,
                    delta: ticketDelta,
                    comparison: comparison
                )
            ),
            DashboardKPI(
                id: "clientMix",
                label: "New / returning",
                value: "\(snapshot.newClientCount) / \(snapshot.returningClientCount)",
                trend: newClientsDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Client mix",
                    "\(snapshot.newClientCount) new, \(snapshot.returningClientCount) returning",
                    delta: newClientsDelta,
                    comparison: comparison,
                    subject: "new clients"
                )
            ),
            DashboardKPI(
                id: "cancellations",
                label: "Cancellation rate",
                value: DashboardFormat.precisePercent(snapshot.cancellationRate),
                trend: cancellationDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Cancellation rate",
                    DashboardFormat.precisePercent(snapshot.cancellationRate),
                    delta: cancellationDelta,
                    comparison: comparison
                )
            ),
        ]
    }

    /// The two secondary sales tiles (memberships and retail products).
    static func salesKPIs(
        for snapshot: DashboardSnapshot,
        previous: DashboardSnapshot?,
        period: DashboardPeriod
    ) -> [DashboardKPI] {
        let comparison = period.comparisonCaption
        let membershipDelta = relativeDelta(
            current: Double(snapshot.membershipsSold),
            previous: previous.map { Double($0.membershipsSold) }
        )
        let productDelta = relativeDelta(
            current: Double(snapshot.productsSold),
            previous: previous.map { Double($0.productsSold) }
        )

        return [
            DashboardKPI(
                id: "memberships",
                label: "Memberships sold",
                value: DashboardFormat.integer(snapshot.membershipsSold),
                trend: membershipDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Memberships sold",
                    DashboardFormat.integer(snapshot.membershipsSold),
                    delta: membershipDelta,
                    comparison: comparison
                )
            ),
            DashboardKPI(
                id: "products",
                label: "Products sold",
                value: DashboardFormat.integer(snapshot.productsSold),
                trend: productDelta?.statTileTrend,
                sparkline: [],
                accessibilityLabel: sentence(
                    "Retail products sold",
                    DashboardFormat.integer(snapshot.productsSold),
                    delta: productDelta,
                    comparison: comparison
                )
            ),
        ]
    }

    // MARK: Trends

    /// Percentage movement between two comparable totals.
    ///
    /// The trend encodes *performance*, not raw arithmetic direction: pass
    /// `higherIsBetter: false` for metrics such as cancellation rate so an
    /// improvement still reads green.
    static func relativeDelta(
        current: Double,
        previous: Double?,
        higherIsBetter: Bool = true
    ) -> MetricDelta? {
        guard let previous, previous != 0, current.isFinite, previous.isFinite else { return nil }
        let change = (current - previous) / abs(previous)
        guard abs(change) >= flatThreshold else { return MetricDelta(direction: .flat, text: "") }
        let magnitude = abs(change).formatted(.percent.precision(.fractionLength(0...1)))
        let improved = higherIsBetter ? change > 0 : change < 0
        return MetricDelta(
            direction: improved ? .up : .down,
            text: higherIsBetter ? magnitude : "\(magnitude) \(improved ? "better" : "worse")"
        )
    }

    /// Percentage-point movement between two rates expressed as 0…1 fractions.
    static func pointsDelta(
        current: Double,
        previous: Double?,
        higherIsBetter: Bool = true
    ) -> MetricDelta? {
        guard let previous, current.isFinite, previous.isFinite else { return nil }
        let change = (current - previous) * 100
        guard abs(change) >= 0.1 else { return MetricDelta(direction: .flat, text: "") }
        let magnitude = "\(abs(change).formatted(.number.precision(.fractionLength(0...1)))) pts"
        let improved = higherIsBetter ? change > 0 : change < 0
        return MetricDelta(
            direction: improved ? .up : .down,
            text: higherIsBetter ? magnitude : "\(magnitude) \(improved ? "better" : "worse")"
        )
    }

    /// Builds the VoiceOver sentence for a tile, spelling the movement out.
    private static func sentence(
        _ label: String,
        _ value: String,
        delta: MetricDelta?,
        comparison: String,
        subject: String? = nil
    ) -> String {
        guard let delta else { return "\(label): \(value)" }
        let noun = subject ?? "it"
        return switch delta.direction {
        case .up: "\(label): \(value). Up \(delta.text) \(comparison)."
        case .down: "\(label): \(value). Down \(delta.text) \(comparison)."
        case .flat: "\(label): \(value). No change in \(noun) \(comparison)."
        }
    }

    // MARK: Revenue forecast

    /// A dashed continuation of the revenue line.
    ///
    /// The first point repeats the last observed day so the dashed projection
    /// grows out of the solid line instead of floating beside it. Values ease
    /// from the last actual day toward the daily run-rate implied by
    /// `revenueForecast`, so the shape stays believable at any window length.
    static func forecastSeries(
        for snapshot: DashboardSnapshot,
        calendar: Calendar = .current
    ) -> [MetricPoint] {
        let actual = snapshot.revenueSeries.sorted { $0.date < $1.date }
        guard actual.count >= 2, let last = actual.last else { return [] }
        let horizon = max(2, actual.count / 3)
        let dailyForecast = (snapshot.revenueForecast.amount / Decimal(actual.count)).rounded()

        var points: [MetricPoint] = [last]
        for step in 1 ... horizon {
            guard let date = calendar.date(byAdding: .day, value: step, to: last.date) else { continue }
            let weight = Decimal(step) / Decimal(horizon)
            let value = last.value + (dailyForecast - last.value) * weight
            points.append(MetricPoint(date: date, value: value.rounded()))
        }
        return points
    }

    // MARK: Employee ranking

    /// One row of the revenue-by-employee leaderboard.
    struct EmployeeRank: Identifiable, Hashable, Sendable {
        let id: String
        let rank: Int
        let name: String
        let amount: Money
        /// Share of the period's total, 0…1, used for the inline bar.
        let share: Double
    }

    /// Ranks `revenueByEmployee` highest-first with each member's share.
    static func employeeRanking(
        for snapshot: DashboardSnapshot,
        currency: Currency = .eur
    ) -> [EmployeeRank] {
        let sorted = snapshot.revenueByEmployee.sorted { $0.value > $1.value }
        let total = sorted.reduce(Decimal(0)) { $0 + $1.value }
        let totalDouble = total.doubleValue
        return sorted.enumerated().map { index, metric in
            EmployeeRank(
                id: metric.name,
                rank: index + 1,
                name: metric.name,
                amount: Money(metric.value.rounded(), currency),
                share: totalDouble > 0 ? metric.value.doubleValue / totalDouble : 0
            )
        }
    }
}

// MARK: - Occupancy heatmap

/// The hour-by-weekday occupancy grid.
///
/// The analytics contract exposes a single `occupancyRate` for the window, not
/// per-slot telemetry, so the grid distributes that rate across opening hours:
/// each weekday is weighted by its average revenue in the window, each hour by
/// the salon-industry demand curve below, and the whole grid is then scaled so
/// its mean equals the reported occupancy. The result is an honest picture of
/// *where* the period's load sat, and the UI labels it as modelled.
enum OccupancyHeatmap {
    /// Hours rendered on the x-axis (09:00 through 20:00).
    static let hours: [Int] = Array(9 ... 20)

    /// Relative demand per hour — mid-morning and early-evening peaks.
    private static let hourWeights: [Double] = [
        0.55, 0.78, 0.95, 0.88, 0.62, 0.80, 0.98, 1.00, 0.90, 0.72, 0.50, 0.32,
    ]

    /// One cell of the grid.
    struct Cell: Identifiable, Hashable, Sendable {
        /// `Calendar` weekday, 1 = Sunday.
        let weekday: Int
        /// Hour of day, 24-hour clock.
        let hour: Int
        /// Occupancy for the slot, clamped to 0…1.
        let value: Double

        var id: String { "\(weekday)-\(hour)" }
    }

    /// Builds every cell for the snapshot's window.
    static func cells(for snapshot: DashboardSnapshot, calendar: Calendar = .current) -> [Cell] {
        var sums: [Int: Double] = [:]
        var counts: [Int: Double] = [:]
        for point in snapshot.revenueSeries {
            let weekday = calendar.component(.weekday, from: point.date)
            sums[weekday, default: 0] += point.value.doubleValue
            counts[weekday, default: 0] += 1
        }

        var averages: [Int: Double] = [:]
        for (weekday, sum) in sums {
            let count = counts[weekday] ?? 0
            averages[weekday] = count > 0 ? sum / count : 0
        }
        let peak = averages.values.max() ?? 0

        var cells: [Cell] = []
        cells.reserveCapacity(7 * hours.count)
        for weekday in 1 ... 7 {
            let dayWeight = peak > 0 ? (averages[weekday] ?? 0) / peak : 0
            for (index, hour) in hours.enumerated() {
                cells.append(Cell(weekday: weekday, hour: hour, value: dayWeight * hourWeights[index]))
            }
        }

        let mean = cells.reduce(0.0) { $0 + $1.value } / Double(max(cells.count, 1))
        guard mean > 0 else { return cells }
        let scale = snapshot.occupancyRate / mean
        return cells.map {
            Cell(weekday: $0.weekday, hour: $0.hour, value: min(1, max(0, $0.value * scale)))
        }
    }

    /// Weekday numbers in the user's locale order (e.g. Monday-first in the EU).
    static func orderedWeekdays(calendar: Calendar = .current) -> [Int] {
        (0 ..< 7).map { ((calendar.firstWeekday - 1 + $0) % 7) + 1 }
    }

    /// Short localized label for a `Calendar` weekday number.
    static func label(for weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let index = max(0, min(symbols.count - 1, weekday - 1))
        return symbols[index]
    }
}

// MARK: - Multi-location comparison

/// One location in the multi-salon comparison table.
struct LocationPerformance: Identifiable, Hashable, Sendable {
    let id: Salon.ID
    let name: String
    let revenue: Money
    let appointmentCount: Int
    let occupancyRate: Double
    let averageTicket: Money
    /// Share of the organization's total revenue for the window, 0…1.
    let share: Double

    /// Ranks snapshots highest-revenue-first, resolving display names from the
    /// supplied lookup (falling back to a short identifier when a salon record
    /// could not be fetched).
    static func ranking(
        from snapshots: [DashboardSnapshot],
        names: [Salon.ID: String]
    ) -> [LocationPerformance] {
        let total = snapshots.reduce(Decimal(0)) { $0 + $1.revenue.amount }.doubleValue
        return snapshots
            .sorted { $0.revenue.amount > $1.revenue.amount }
            .map { snapshot in
                LocationPerformance(
                    id: snapshot.salonID,
                    name: names[snapshot.salonID] ?? "Location \(snapshot.salonID.description.prefix(4))",
                    revenue: snapshot.revenue,
                    appointmentCount: snapshot.appointmentCount,
                    occupancyRate: snapshot.occupancyRate,
                    averageTicket: snapshot.averageTicket,
                    share: total > 0 ? snapshot.revenue.amount.doubleValue / total : 0
                )
            }
    }
}
