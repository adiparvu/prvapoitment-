import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The deep-dive companion to the dashboard.
///
/// Pick a measure (revenue, bookings, retention, average ticket, conversion),
/// pick a window (quick presets or a custom range chosen with graphical date
/// pickers), then read it three ways: a large scrubable chart with the previous
/// window overlaid, a period-over-period comparison, and a cohort retention
/// grid. Everything on screen can leave as a one-page PDF report or a CSV of the
/// underlying series, both shared through `ShareLink`.
public struct AnalyticsView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    @State private var model = AnalyticsModel()
    @State private var isPickingRange = false

    /// Creates the analytics screen. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                metricPicker
                rangePicker

                switch model.phase {
                case .loading:
                    DashboardSkeleton()
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    content
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.large)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .prvAnimation(PRVMotion.spring, value: model.metric)
        .refreshable { await refresh() }
        .task(id: taskIdentity) { await refresh() }
        .sheet(isPresented: $isPickingRange) {
            DateRangeSheet(start: model.customStart, end: model.customEnd) { start, end in
                model.applyCustomRange(start: start, end: end)
            }
            .presentationDetents([.large])
            .presentationBackground(.regularMaterial)
        }
        .prvToast($model.toast)
    }

    // MARK: - Pickers

    private var metricPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PRVSpacing.xs) {
                ForEach(AnalyticsMetric.allCases) { metric in
                    PRVChip(
                        metric.title,
                        systemImage: metric.symbolName,
                        isSelected: model.metric == metric
                    ) {
                        model.metric = metric
                    }
                }
            }
            .padding(.vertical, PRVSpacing.xxs)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -PRVSpacing.lg)
        .contentMargins(.horizontal, PRVSpacing.lg, for: .scrollContent)
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            PRVSegmentedGlassControl(
                selection: presetBinding,
                options: AnalyticsRangePreset.allCases,
                title: \.title
            )

            Button {
                PRVHaptics.tap()
                isPickingRange = true
            } label: {
                HStack(spacing: PRVSpacing.xxs) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(model.rangeTitle)
                        .font(.footnote.weight(.medium))
                    Text("· \(model.dayCount) days")
                        .prvStyle(.caption)
                }
                .foregroundStyle(Color.prv.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reporting window: \(model.rangeTitle), \(model.dayCount) days. Double tap to choose custom dates.")
        }
    }

    /// Selecting "Custom" opens the date pickers; the preset only flips to
    /// `.custom` once a range is actually applied.
    private var presetBinding: Binding<AnalyticsRangePreset> {
        Binding(
            get: { model.preset },
            set: { newValue in
                if newValue == .custom {
                    isPickingRange = true
                } else {
                    model.select(preset: newValue)
                }
            }
        )
    }

    // MARK: - States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "chart.xyaxis.line",
            title: "Analytics unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    @ViewBuilder
    private var content: some View {
        headlineCard

        AnalyticsChartCard(
            metric: model.metric,
            series: model.series,
            previousSeries: model.previousSeries,
            currency: model.currency
        )

        DashboardSection(
            "Period Comparison",
            subtitle: "This window against the one before it"
        ) {
            PeriodComparisonChart(
                metric: model.metric,
                current: model.currentTotal,
                previous: model.previousTotal,
                currency: model.currency
            )
        }

        DashboardSection(
            "Cohort Retention",
            subtitle: "How each month's new clients keep coming back"
        ) {
            RetentionCohortGrid(cohorts: model.cohorts, columnCount: model.cohortColumnCount)
        }

        DashboardSection(
            "Export",
            subtitle: "Take this window with you"
        ) {
            exportCard
        }
    }

    // MARK: - Headline

    private var headlineCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: model.metric.symbolName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                        .accessibilityHidden(true)
                    Text(model.metric.title)
                        .prvStyle(.footnote)
                }

                Text(model.headline)
                    .prvStyle(.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if let delta = model.headlineDelta {
                    HStack(spacing: PRVSpacing.xxs) {
                        Image(systemName: delta.symbolName)
                            .font(.caption2.weight(.bold))
                        Text(delta.direction == .flat ? "No change" : delta.text)
                            .font(.caption.weight(.semibold))
                        if let previous = model.previousHeadline {
                            Text("· was \(previous)")
                                .prvStyle(.caption)
                        }
                    }
                    .foregroundStyle(delta.tint)
                }

                Text(model.metric.explanation)
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PRVSpacing.xxs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headlineAccessibilityLabel)
    }

    private var headlineAccessibilityLabel: String {
        var label = "\(model.metric.title): \(model.headline)."
        if let delta = model.headlineDelta {
            label += " \(delta.spokenText.capitalizedFirst) against the previous window."
        }
        if let previous = model.previousHeadline {
            label += " Previously \(previous)."
        }
        return label
    }

    // MARK: - Export

    private var exportCard: some View {
        VStack(spacing: PRVSpacing.md) {
            exportRow(
                title: "PDF report",
                subtitle: "A one-page summary of this window",
                systemImage: "doc.richtext",
                actionTitle: "Export PDF",
                fileURL: model.pdfFileURL,
                shareLabel: "Share PDF report",
                action: exportPDF
            )

            Divider().overlay(Color.prv.separator.opacity(0.5))

            exportRow(
                title: "CSV data",
                subtitle: "Every day in the window, plus totals",
                systemImage: "tablecells",
                actionTitle: "Export CSV",
                fileURL: model.csvFileURL,
                shareLabel: "Share CSV data",
                action: { model.exportCSV() }
            )
        }
        .prvGlassCard()
    }

    private func exportRow(
        title: String,
        subtitle: String,
        systemImage: String,
        actionTitle: String,
        fileURL: URL?,
        shareLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: PRVSpacing.sm) {
            PRVListRowIcon(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(subtitle)
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            if let fileURL {
                ShareLink(item: fileURL) {
                    HStack(spacing: PRVSpacing.xxs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                        Text("Share")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.prv.textOnAccent)
                    .padding(.vertical, PRVSpacing.xs)
                    .padding(.horizontal, PRVSpacing.sm)
                    .background(Color.prv.accentGradient, in: Capsule())
                }
                .accessibilityLabel(shareLabel)
            } else {
                Button(actionTitle) {
                    PRVHaptics.impact()
                    action()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .buttonStyle(.plain)
                .accessibilityLabel(actionTitle)
                .accessibilityHint("Prepares the file, then offers a share button")
            }
        }
        .prvAnimation(PRVMotion.spring, value: fileURL)
    }

    /// Renders the print-styled report into a temporary PDF and hands the URL
    /// to the model, which surfaces the `ShareLink`.
    private func exportPDF() {
        guard let snapshot = model.snapshot else { return }
        let report = AnalyticsReportView(
            salonName: model.salonName,
            metric: model.metric,
            rangeTitle: model.rangeTitle,
            snapshot: snapshot,
            series: model.series,
            currency: model.currency,
            generatedAt: .now
        )
        model.attachPDF(AnalyticsExport.renderPDF(report, fileName: model.pdfFileName))
    }

    // MARK: - Loading

    /// The salon in scope, falling back to the flagship fixture so previews and
    /// demo mode always have something to report on.
    private var salonID: Salon.ID {
        session.activeSalonID ?? PreviewData.salonLumiere.id
    }

    /// Reload whenever the salon or the window changes; changing the metric
    /// only re-derives from the snapshot already in memory.
    private var taskIdentity: String {
        "\(salonID.description)-\(model.range.start.timeIntervalSince1970)-\(model.range.end.timeIntervalSince1970)"
    }

    private func refresh() async {
        await model.load(salonID: salonID, using: deps)
    }

    private func reload() {
        let salonID = salonID
        let deps = deps
        Task { await model.load(salonID: salonID, using: deps) }
    }
}

// MARK: - Helpers

extension String {
    /// Uppercases the first character only — used to start VoiceOver sentences
    /// built from lowercase fragments.
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Previews

#Preview("Analytics — Owner") {
    NavigationStack {
        AnalyticsView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .dashboard))
}

#Preview("Analytics — Dark") {
    NavigationStack {
        AnalyticsView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .dashboard))
    .preferredColorScheme(.dark)
}
