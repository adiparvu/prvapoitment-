import Charts
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Main metric chart

/// The analytics screen's large chart: the selected metric as a gradient area
/// with its line, an optional faded overlay of the previous window aligned day
/// for day, and scrubbing that shows both values at once.
struct AnalyticsChartCard: View {
    let metric: AnalyticsMetric
    let series: [MetricPoint]
    let previousSeries: [MetricPoint]
    let currency: Currency

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selectedDate: Date?
    @State private var showsPrevious = true

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            controls

            if series.isEmpty {
                PRVEmptyState(
                    systemImage: "chart.xyaxis.line",
                    title: "Nothing to plot",
                    message: "Pick a wider date range, or come back once the period has activity."
                )
            } else {
                chart
                    .frame(height: 280)
                    .prvAnimation(PRVMotion.gentle, value: series)

                if metric.hasModelledSeries {
                    DashboardFootnote(
                        "The period total is exact; the daily shape is distributed by each day's revenue weight."
                    )
                }
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: PRVSpacing.xs) {
            Text(metric.title)
                .prvStyle(.headline)

            Spacer(minLength: PRVSpacing.xs)

            if !previousSeries.isEmpty {
                PRVChip(
                    "vs previous",
                    systemImage: "arrow.left.arrow.right",
                    isSelected: showsPrevious
                ) {
                    showsPrevious.toggle()
                }
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(series) { point in
                AreaMark(
                    x: .value("Day", point.date),
                    y: .value(metric.title, point.value.doubleValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(areaGradient)
            }

            ForEach(series) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value(metric.title, point.value.doubleValue),
                    series: .value("Window", "Current")
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.prv.accent)
            }

            ForEach(alignedPrevious) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value(metric.title, point.value.doubleValue),
                    series: .value("Window", "Previous")
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
                .foregroundStyle(Color.prv.textSecondary.opacity(0.7))
            }

            if let selection {
                RuleMark(x: .value("Day", selection.current.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.prv.accent.opacity(0.45))
                    .annotation(
                        position: .top,
                        spacing: PRVSpacing.xs,
                        overflowResolution: .init(x: .fitToChart, y: .disabled)
                    ) {
                        lollipop(for: selection)
                    }

                PointMark(
                    x: .value("Day", selection.current.date),
                    y: .value(metric.title, selection.current.value.doubleValue)
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
                        Text(metric.axisFormat(amount, currency: currency))
                            .prvStyle(.caption)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
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
        .accessibilityLabel("\(metric.title) over time")
        .accessibilityValue(accessibilitySummary)
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [Color.prv.accent.opacity(0.32), Color.prv.accent.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The previous window's values re-dated onto the current window so the two
    /// lines can be read against each other day by day.
    private var alignedPrevious: [MetricPoint] {
        guard showsPrevious else { return [] }
        let count = min(series.count, previousSeries.count)
        guard count > 1 else { return [] }
        return (0 ..< count).map { index in
            MetricPoint(date: series[index].date, value: previousSeries[index].value)
        }
    }

    /// Current and comparison values at the scrub position.
    private struct Selection {
        let current: MetricPoint
        let previous: MetricPoint?
    }

    private var selection: Selection? {
        guard let selectedDate,
              let current = series.min(by: {
                  abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
              })
        else { return nil }
        let previous = alignedPrevious.first { $0.date == current.date }
        return Selection(current: current, previous: previous)
    }

    private func lollipop(for selection: Selection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selection.current.date.formatted(date: .abbreviated, time: .omitted))
                .prvStyle(.caption)
            Text(metric.format(selection.current.value.doubleValue, currency: currency))
                .prvStyle(.headline)
                .monospacedDigit()
            if let previous = selection.previous {
                Text("was \(metric.format(previous.value.doubleValue, currency: currency))")
                    .prvStyle(.caption)
                    .monospacedDigit()
            }
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

    private var accessibilitySummary: String {
        guard let first = series.first, let last = series.last else { return "No data" }
        var summary = "From \(first.date.formatted(date: .abbreviated, time: .omitted)) "
        summary += "to \(last.date.formatted(date: .abbreviated, time: .omitted)). "
        if let peak = series.max(by: { $0.value < $1.value }) {
            summary += "Peak \(metric.format(peak.value.doubleValue, currency: currency)) "
            summary += "on \(peak.date.formatted(date: .abbreviated, time: .omitted))."
        }
        return summary
    }
}

// MARK: - Period comparison

/// Two bars — this window against the one before it — for the selected metric.
struct PeriodComparisonChart: View {
    let metric: AnalyticsMetric
    let current: Double
    let previous: Double?
    let currency: Currency

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            if let previous {
                Chart {
                    BarMark(
                        x: .value("Value", previous),
                        y: .value("Window", "Previous")
                    )
                    .foregroundStyle(Color.prv.textSecondary.opacity(0.35))
                    .cornerRadius(PRVRadius.sm / 2)
                    .annotation(
                        position: .trailing,
                        spacing: PRVSpacing.xs,
                        overflowResolution: .init(x: .fitToChart, y: .disabled)
                    ) {
                        label(previous)
                    }

                    BarMark(
                        x: .value("Value", current),
                        y: .value("Window", "Current")
                    )
                    .foregroundStyle(Color.prv.accentGradient)
                    .cornerRadius(PRVRadius.sm / 2)
                    .annotation(
                        position: .trailing,
                        spacing: PRVSpacing.xs,
                        overflowResolution: .init(x: .fitToChart, y: .disabled)
                    ) {
                        label(current)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading) { _ in
                        AxisValueLabel()
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 108)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(metric.title), this period against the previous period")
                .accessibilityValue(
                    "Current \(metric.format(current, currency: currency)), previous \(metric.format(previous, currency: currency))"
                )
            } else {
                Text("No comparable period yet — this is your first window of data.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .prvGlassCard()
    }

    private func label(_ value: Double) -> some View {
        Text(metric.format(value, currency: currency))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.prv.textSecondary)
            .monospacedDigit()
    }
}

// MARK: - Retention cohorts

/// A cohort retention grid: one row per acquisition month, one column per month
/// since acquisition, cells tinted by how much of the cohort is still active.
struct RetentionCohortGrid: View {
    let cohorts: [RetentionCohort]
    let columnCount: Int

    private var cellWidth: CGFloat { 52 }
    private var labelWidth: CGFloat { 92 }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            if cohorts.isEmpty || columnCount == 0 {
                Text("Cohorts appear once the salon has a few months of history.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        headerRow
                        ForEach(cohorts) { cohort in
                            row(for: cohort)
                        }
                    }
                    .padding(.vertical, PRVSpacing.xxs)
                }
                .scrollIndicators(.hidden)

                DashboardFootnote(
                    "Cohorts projected from the period's retention rate until per-client history is exposed by the reporting API."
                )
            }
        }
        .prvGlassCard()
    }

    private var headerRow: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Text("Cohort")
                .prvStyle(.caption)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(Array(0 ..< columnCount), id: \.self) { column in
                Text("M\(column)")
                    .prvStyle(.caption)
                    .frame(width: cellWidth)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(for cohort: RetentionCohort) -> some View {
        HStack(spacing: PRVSpacing.xxs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(cohort.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                Text("\(cohort.size) clients")
                    .prvStyle(.caption)
            }
            .frame(width: labelWidth, alignment: .leading)

            ForEach(Array(0 ..< columnCount), id: \.self) { column in
                cell(for: cohort, column: column)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: cohort))
    }

    @ViewBuilder
    private func cell(for cohort: RetentionCohort, column: Int) -> some View {
        if column < cohort.retention.count {
            let value = cohort.retention[column]
            Text(DashboardFormat.percent(value))
                .font(.caption.weight(.semibold))
                .foregroundStyle(value > 0.55 ? Color.prv.textOnAccent : Color.prv.textPrimary)
                .monospacedDigit()
                .frame(width: cellWidth, height: 34)
                .background(
                    Color.prv.accent.opacity(0.12 + 0.8 * value),
                    in: PRVRadius.shape(PRVRadius.sm)
                )
        } else {
            PRVRadius.shape(PRVRadius.sm)
                .fill(Color.prv.separator.opacity(0.18))
                .frame(width: cellWidth, height: 34)
        }
    }

    private func accessibilityLabel(for cohort: RetentionCohort) -> String {
        let detail = cohort.retention.enumerated()
            .map { "month \($0.offset) \(DashboardFormat.percent($0.element))" }
            .joined(separator: ", ")
        return "Cohort \(cohort.title), \(cohort.size) clients: \(detail)."
    }
}

// MARK: - Custom range

/// Graphical start/end pickers for a custom reporting window.
struct DateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date

    private let apply: (Date, Date) -> Void

    /// Creates the sheet seeded with the window currently on screen.
    init(start: Date, end: Date, apply: @escaping (Date, Date) -> Void) {
        self._start = State(initialValue: start)
        self._end = State(initialValue: end)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                    picker(title: "From", selection: $start, range: ...Date.now)
                    picker(title: "To", selection: $end, range: start ... Date.now)

                    summary
                }
                .padding(PRVSpacing.lg)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        PRVHaptics.impact()
                        apply(min(start, end), max(start, end))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func picker(
        title: String,
        selection: Binding<Date>,
        range: PartialRangeThrough<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Text(title)
                .prvStyle(.headline)
            DatePicker(title, selection: selection, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.prv.accent)
                .labelsHidden()
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
    }

    private func picker(
        title: String,
        selection: Binding<Date>,
        range: ClosedRange<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Text(title)
                .prvStyle(.headline)
            DatePicker(title, selection: selection, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.prv.accent)
                .labelsHidden()
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
    }

    private var summary: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: "calendar")
                .foregroundStyle(Color.prv.accent)
                .accessibilityHidden(true)
            Text(DashboardFormat.rangeTitle(DateInterval(start: min(start, end), end: max(start, end).adding(days: 1))))
                .prvStyle(.footnote)
            Spacer(minLength: 0)
            Text("\(dayCount) days")
                .prvStyle(.caption)
                .monospacedDigit()
        }
        .prvGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var dayCount: Int {
        let days = Calendar.current.dateComponents(
            [.day],
            from: min(start, end).startOfDay(),
            to: max(start, end).startOfDay()
        ).day ?? 0
        return days + 1
    }
}
