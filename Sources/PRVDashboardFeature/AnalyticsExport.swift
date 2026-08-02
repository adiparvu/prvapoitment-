import CoreGraphics
import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Turns an analytics window into shareable artefacts: a CSV of the plotted
/// series and a one-page PDF report rendered from SwiftUI with `ImageRenderer`.
///
/// Both artefacts are written into the temporary directory with deterministic
/// names, so re-exporting the same window overwrites rather than accumulating.
enum AnalyticsExport {
    // MARK: CSV

    /// Builds the CSV document for a metric and its series.
    ///
    /// The file leads with a small metadata block (salon, metric, window,
    /// currency, headline totals) so a spreadsheet opened three months later
    /// still explains itself, followed by the `Date,Value` rows.
    static func csvText(
        metric: AnalyticsMetric,
        snapshot: DashboardSnapshot,
        series: [MetricPoint],
        salonName: String,
        currency: Currency
    ) -> String {
        var lines: [String] = []

        lines.append("PRV Beauty analytics export")
        lines.append(row("Salon", salonName))
        lines.append(row("Metric", metric.title))
        lines.append(row("Period start", isoDay(snapshot.periodStart)))
        lines.append(row("Period end", isoDay(snapshot.periodEnd)))
        lines.append(row("Currency", currency.rawValue))
        lines.append(row("Generated", Date.now.formatted(.iso8601)))
        lines.append("")
        lines.append(row("Revenue", decimalField(snapshot.revenue.amount)))
        lines.append(row("Appointments", "\(snapshot.appointmentCount)"))
        lines.append(row("Completed", "\(snapshot.completedCount)"))
        lines.append(row("Occupancy rate", rateField(snapshot.occupancyRate)))
        lines.append(row("Cancellation rate", rateField(snapshot.cancellationRate)))
        lines.append(row("Retention rate", rateField(snapshot.retentionRate)))
        lines.append(row("Average ticket", decimalField(snapshot.averageTicket.amount)))
        lines.append(row("New clients", "\(snapshot.newClientCount)"))
        lines.append(row("Returning clients", "\(snapshot.returningClientCount)"))
        lines.append(row("Memberships sold", "\(snapshot.membershipsSold)"))
        lines.append(row("Products sold", "\(snapshot.productsSold)"))
        lines.append("")
        lines.append(row("Date", metric.title))

        for point in series.sorted(by: { $0.date < $1.date }) {
            lines.append(row(isoDay(point.date), decimalField(point.value)))
        }

        if !snapshot.revenueByService.isEmpty {
            lines.append("")
            lines.append(row("Service", "Revenue"))
            for entry in snapshot.revenueByService.sorted(by: { $0.value > $1.value }) {
                lines.append(row(entry.name, decimalField(entry.value)))
            }
        }

        if !snapshot.revenueByEmployee.isEmpty {
            lines.append("")
            lines.append(row("Team member", "Revenue"))
            for entry in snapshot.revenueByEmployee.sorted(by: { $0.value > $1.value }) {
                lines.append(row(entry.name, decimalField(entry.value)))
            }
        }

        return lines.joined(separator: "\n").appending("\n")
    }

    /// Joins two escaped fields into a CSV row.
    private static func row(_ left: String, _ right: String) -> String {
        "\(escape(left)),\(escape(right))"
    }

    /// RFC 4180 escaping: quote when the value contains a comma, quote, or
    /// newline, and double any embedded quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Locale- and time-zone-independent `YYYY-MM-DD`, computed from calendar
    /// components so a local start-of-day never slips into the previous day.
    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Machine-readable, locale-independent decimal (always a dot separator).
    private static func decimalField(_ value: Decimal) -> String {
        value.doubleValue.formatted(
            .number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))
        )
    }

    /// Machine-readable rate with four decimals, e.g. `0.0600`.
    private static func rateField(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(4)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))
        )
    }

    // MARK: Files

    /// A filesystem-safe, self-describing artefact name.
    static func fileName(
        salonName: String,
        metric: AnalyticsMetric,
        range: DateInterval,
        fileExtension: String,
        calendar: Calendar = .current
    ) -> String {
        let last = range.end.adding(days: -1, calendar: calendar)
        let slug = slugify(salonName)
        let from = isoDay(range.start, calendar: calendar)
        let to = isoDay(last, calendar: calendar)
        return "\(slug)-\(metric.rawValue)-\(from)-to-\(to).\(fileExtension)"
    }

    /// Lowercases and strips anything that is not alphanumeric or a dash.
    static func slugify(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let mapped = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .lowercased()
        return collapsed.isEmpty ? "report" : collapsed
    }

    /// Writes UTF-8 text into the temporary directory and returns its URL.
    static func write(_ text: String, fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: PDF

    /// Renders a SwiftUI view into a single-page PDF in the temporary
    /// directory. Returns `nil` when the renderer produces nothing (an empty
    /// report) or the file cannot be created.
    ///
    /// The page is sized to the rendered content at A4 width, which keeps the
    /// layout crisp and avoids fighting PDF's bottom-left coordinate space.
    @MainActor
    static func renderPDF(_ content: some View, fileName: String) -> URL? {
        let pageWidth: CGFloat = 595
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var result: URL?

        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard size.width > 0, size.height > 0,
                  let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else { return }

            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            result = url
        }

        return result
    }
}

// MARK: - Printable report

/// The print-styled report handed to `ImageRenderer`.
///
/// It deliberately looks nothing like the app: a light page, generous margins,
/// a rule under the masthead, and a KPI table — the thing an accountant expects
/// in their inbox. Design tokens still drive every colour and spacing value so
/// the report stays on brand.
struct AnalyticsReportView: View {
    let salonName: String
    let metric: AnalyticsMetric
    let rangeTitle: String
    let snapshot: DashboardSnapshot
    let series: [MetricPoint]
    let currency: Currency
    let generatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            masthead

            Rectangle()
                .fill(Color.prv.accentGradient)
                .frame(height: 3)

            headline

            if series.count > 1 {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Daily \(metric.title.lowercased())")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textSecondary)
                    PRVSparkline(values: series.map(\.value.doubleValue))
                        .frame(height: 90)
                }
            }

            table

            if !snapshot.revenueByService.isEmpty {
                breakdown("Revenue by service", metrics: snapshot.revenueByService)
            }

            if !snapshot.revenueByEmployee.isEmpty {
                breakdown("Revenue by team member", metrics: snapshot.revenueByEmployee)
            }

            Spacer(minLength: 0)

            Text("Generated \(generatedAt.formatted(date: .long, time: .shortened)) · PRV Beauty")
                .font(.caption2)
                .foregroundStyle(Color.prv.textSecondary)
        }
        .padding(40)
        .frame(width: 595, alignment: .topLeading)
        .background(Color.prv.canvas)
        .environment(\.colorScheme, .light)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(salonName)
                .prvStyle(.title)
            Text("\(metric.title) report · \(rangeTitle)")
                .font(.subheadline)
                .foregroundStyle(Color.prv.textSecondary)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(metric.headline(for: snapshot, currency: currency))
                .prvStyle(.display)
            Text(metric.explanation)
                .font(.footnote)
                .foregroundStyle(Color.prv.textSecondary)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            reportRow("Revenue", snapshot.revenue.formatted, isHeader: true)
            reportRow("Appointments", DashboardFormat.integer(snapshot.appointmentCount))
            reportRow("Completed", DashboardFormat.integer(snapshot.completedCount))
            reportRow("Occupancy", DashboardFormat.percent(snapshot.occupancyRate))
            reportRow("Cancellation rate", DashboardFormat.precisePercent(snapshot.cancellationRate))
            reportRow("Retention", DashboardFormat.precisePercent(snapshot.retentionRate))
            reportRow("Average ticket", snapshot.averageTicket.formatted)
            reportRow("New clients", DashboardFormat.integer(snapshot.newClientCount))
            reportRow("Returning clients", DashboardFormat.integer(snapshot.returningClientCount))
            reportRow("Memberships sold", DashboardFormat.integer(snapshot.membershipsSold))
            reportRow("Products sold", DashboardFormat.integer(snapshot.productsSold))
        }
    }

    private func breakdown(_ title: String, metrics: [NamedMetric]) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary)
            VStack(spacing: 0) {
                ForEach(metrics.sorted { $0.value > $1.value }) { metric in
                    reportRow(
                        metric.name,
                        DashboardFormat.currency(metric.value.doubleValue, currency: currency)
                    )
                }
            }
        }
    }

    private func reportRow(_ label: String, _ value: String, isHeader: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(Color.prv.textPrimary)
                Spacer(minLength: PRVSpacing.md)
                Text(value)
                    .font(isHeader ? .subheadline.weight(.bold) : .subheadline.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
            }
            .padding(.vertical, PRVSpacing.xs)

            Rectangle()
                .fill(Color.prv.separator.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}
