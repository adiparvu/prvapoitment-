import Charts
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Revenue

/// The dashboard's hero chart: a gradient revenue area with its line, a dashed
/// forecast that grows out of the last observed day, and touch scrubbing that
/// parks a Liquid Glass lollipop over the selected day.
struct RevenueChartCard: View {
    let actual: [MetricPoint]
    let forecast: [MetricPoint]
    let currency: Currency
    let periodCaption: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            header

            if actual.isEmpty {
                PRVEmptyState(
                    systemImage: "chart.line.uptrend.xyaxis",
                    title: "No revenue yet",
                    message: "Completed appointments and retail sales appear here as soon as they are closed out."
                )
            } else {
                chart
                    .frame(height: 224)
                    .prvAnimation(PRVMotion.gentle, value: actual)

                legend
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text("Revenue")
                .prvStyle(.headline)
            Text(headerDetail)
                .prvStyle(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headerDetail: String {
        guard let peak = actual.max(by: { $0.value < $1.value }) else { return periodCaption }
        let peakLabel = DashboardFormat.axisDay(peak.date)
        return "\(periodCaption) · best day \(peakLabel), \(DashboardFormat.compactCurrency(peak.value.doubleValue, currency: currency))"
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(actual) { point in
                AreaMark(
                    x: .value("Day", point.date),
                    y: .value("Revenue", point.value.doubleValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(areaGradient)
            }

            ForEach(actual) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Revenue", point.value.doubleValue),
                    series: .value("Series", "Actual")
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.prv.accent)
            }

            ForEach(forecast) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Revenue", point.value.doubleValue),
                    series: .value("Series", "Forecast")
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                .foregroundStyle(Color.prv.gold)
            }

            if let selectedPoint {
                RuleMark(x: .value("Day", selectedPoint.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.prv.accent.opacity(0.45))
                    .annotation(
                        position: .top,
                        spacing: PRVSpacing.xs,
                        overflowResolution: .init(x: .fitToChart, y: .disabled)
                    ) {
                        lollipop(for: selectedPoint)
                    }

                PointMark(
                    x: .value("Day", selectedPoint.date),
                    y: .value("Revenue", selectedPoint.value.doubleValue)
                )
                .symbolSize(90)
                .foregroundStyle(Color.prv.accent)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.prv.separator.opacity(0.35))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(DashboardFormat.compactCurrency(amount, currency: currency))
                            .prvStyle(.caption)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(DashboardFormat.axisDay(date))
                            .prvStyle(.caption)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Revenue chart")
        .accessibilityValue(accessibilitySummary)
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [Color.prv.accent.opacity(0.35), Color.prv.accent.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The observed day nearest the scrub position.
    private var selectedPoint: MetricPoint? {
        guard let selectedDate else { return nil }
        return actual.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    /// The floating glass readout parked above the scrubbed day.
    private func lollipop(for point: MetricPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.date.formatted(date: .abbreviated, time: .omitted))
                .prvStyle(.caption)
            Text(DashboardFormat.currency(point.value.doubleValue, currency: currency))
                .prvStyle(.headline)
                .monospacedDigit()
        }
        .padding(.vertical, PRVSpacing.xs)
        .padding(.horizontal, PRVSpacing.sm)
        .background {
            if reduceTransparency {
                PRVRadius.shape(PRVRadius.sm).fill(Color.prv.surfaceElevated)
            } else {
                PRVRadius.shape(PRVRadius.sm).fill(.regularMaterial)
            }
        }
        .overlay {
            PRVRadius.shape(PRVRadius.sm)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        .prvSoftShadow()
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: PRVSpacing.md) {
            legendSwatch(color: Color.prv.accent, title: "Actual", isDashed: false)
            if !forecast.isEmpty {
                legendSwatch(color: Color.prv.gold, title: "Forecast", isDashed: true)
            }
            Spacer(minLength: 0)
            if selectedDate != nil {
                Button("Clear") {
                    PRVHaptics.tap()
                    selectedDate = nil
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("Clear chart selection")
            }
        }
    }

    private func legendSwatch(color: Color, title: String, isDashed: Bool) -> some View {
        HStack(spacing: PRVSpacing.xxs) {
            LegendLine()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: isDashed ? [4, 3] : [])
                )
                .frame(width: 20, height: 3)
                .accessibilityHidden(true)
            Text(title)
                .prvStyle(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibilitySummary: String {
        let total = actual.reduce(Decimal(0)) { $0 + $1.value }
        var summary = "\(periodCaption). Total \(DashboardFormat.currency(total.doubleValue, currency: currency)) across \(actual.count) days."
        if let peak = actual.max(by: { $0.value < $1.value }) {
            summary += " Best day \(peak.date.formatted(date: .abbreviated, time: .omitted)), \(DashboardFormat.currency(peak.value.doubleValue, currency: currency))."
        }
        if let last = forecast.last {
            summary += " Forecast reaches \(DashboardFormat.currency(last.value.doubleValue, currency: currency)) per day."
        }
        return summary
    }
}

/// A single horizontal rule used for chart legend swatches, strokeable with a
/// dash pattern so "forecast" reads the same in the legend as on the plot.
private struct LegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Revenue by service

/// Horizontal bars ranking the window's revenue by service.
struct RevenueByServiceChart: View {
    let metrics: [NamedMetric]
    let currency: Currency

    var body: some View {
        Group {
            if metrics.isEmpty {
                Text("No service revenue in this window yet.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(metrics) { metric in
                    BarMark(
                        x: .value("Revenue", metric.value.doubleValue),
                        y: .value("Service", metric.name)
                    )
                    .foregroundStyle(Color.prv.accentGradient)
                    .cornerRadius(PRVRadius.sm / 2)
                    .annotation(
                        position: .trailing,
                        spacing: PRVSpacing.xs,
                        overflowResolution: .init(x: .fitToChart, y: .disabled)
                    ) {
                        Text(DashboardFormat.compactCurrency(metric.value.doubleValue, currency: currency))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.prv.textSecondary)
                            .monospacedDigit()
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading) { _ in
                        AxisValueLabel()
                    }
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(metrics.count) * 46 + 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Revenue by service")
                .accessibilityValue(accessibilitySummary)
            }
        }
        .prvGlassCard()
    }

    private var accessibilitySummary: String {
        metrics
            .map { "\($0.name), \(DashboardFormat.currency($0.value.doubleValue, currency: currency))" }
            .joined(separator: ". ")
    }
}

// MARK: - Revenue by employee

/// A ranked leaderboard of team revenue with proportional bars.
struct RevenueByEmployeeList: View {
    let ranking: [DashboardMetrics.EmployeeRank]

    var body: some View {
        VStack(spacing: PRVSpacing.md) {
            if ranking.isEmpty {
                Text("No team revenue recorded in this window.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(ranking) { entry in
                    row(for: entry)
                }
            }
        }
        .prvGlassCard()
    }

    private func row(for entry: DashboardMetrics.EmployeeRank) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(spacing: PRVSpacing.sm) {
                Text("\(entry.rank)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(entry.rank == 1 ? Color.prv.gold : Color.prv.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        (entry.rank == 1 ? Color.prv.gold : Color.prv.textSecondary).opacity(0.14),
                        in: Circle()
                    )
                    .accessibilityHidden(true)

                Text(entry.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: PRVSpacing.xs)

                Text(entry.amount.formatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
            }

            shareBar(for: entry.share)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Rank \(entry.rank), \(entry.name), \(entry.amount.formatted), \(DashboardFormat.percent(entry.share)) of team revenue"
        )
    }

    private func shareBar(for share: Double) -> some View {
        Capsule()
            .fill(Color.prv.separator.opacity(0.35))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.prv.accentGradient)
                        .frame(width: max(0, proxy.size.width * share))
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Occupancy heatmap

/// Hour-by-weekday occupancy, rendered as a `RectangleMark` grid tinted with
/// the brand accent. The distribution is modelled from the window's occupancy
/// rate and daily revenue mix, which the caller states in a footnote.
struct OccupancyHeatmapChart: View {
    let cells: [OccupancyHeatmap.Cell]
    let calendar: Calendar

    init(cells: [OccupancyHeatmap.Cell], calendar: Calendar = .current) {
        self.cells = cells
        self.calendar = calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            if cells.isEmpty {
                Text("Occupancy appears once the window has bookings.")
                    .prvStyle(.footnote)
            } else {
                Chart(cells) { cell in
                    RectangleMark(
                        xStart: .value("From", cell.hour),
                        xEnd: .value("To", cell.hour + 1),
                        y: .value("Day", OccupancyHeatmap.label(for: cell.weekday, calendar: calendar)),
                        height: .ratio(0.82)
                    )
                    .foregroundStyle(Color.prv.accent.opacity(0.10 + 0.85 * cell.value))
                }
                .chartYScale(domain: weekdayLabels)
                .chartXAxis {
                    AxisMarks(values: [9, 12, 15, 18, 21]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(DashboardFormat.hourLabel(hour))
                                    .prvStyle(.caption)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading) { _ in
                        AxisValueLabel()
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 208)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Occupancy heatmap by hour and weekday")
                .accessibilityValue(accessibilitySummary)

                scaleLegend
            }
        }
        .prvGlassCard()
    }

    private var weekdayLabels: [String] {
        OccupancyHeatmap.orderedWeekdays(calendar: calendar)
            .map { OccupancyHeatmap.label(for: $0, calendar: calendar) }
    }

    private var scaleLegend: some View {
        HStack(spacing: PRVSpacing.xs) {
            Text("Quiet")
                .prvStyle(.caption)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.prv.accent.opacity(0.10), Color.prv.accent.opacity(0.95)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 8)
            Text("Full")
                .prvStyle(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour scale runs from quiet to fully booked")
    }

    private var accessibilitySummary: String {
        guard let busiest = cells.max(by: { $0.value < $1.value }) else { return "No data" }
        let day = OccupancyHeatmap.label(for: busiest.weekday, calendar: calendar)
        return "Busiest slot \(day) at \(DashboardFormat.hourLabel(busiest.hour)) hundred, \(DashboardFormat.percent(busiest.value)) full."
    }
}
