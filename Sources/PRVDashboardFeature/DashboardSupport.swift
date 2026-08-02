import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Phase

/// Loading lifecycle of a business-intelligence screen.
///
/// Dashboards are expensive to assemble, so the whole screen shares one phase
/// while individual sections (timeline, multi-location) keep their own inline
/// error strings — a failing side-section never blacks out the KPIs.
enum DashboardPhase: Equatable, Sendable {
    /// The first load is in flight; render skeletons.
    case loading
    /// Data is on screen (possibly being refreshed in the background).
    case loaded
    /// The load failed with human-readable copy.
    case failed(String)

    /// Whether the screen is still waiting for its first payload.
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Period

/// The dashboard's headline reporting window.
///
/// Every window ends at the end of today so "Week" and "Month" are rolling
/// windows rather than calendar buckets — the number a salon owner actually
/// asks for ("how are we doing lately?").
enum DashboardPeriod: String, CaseIterable, Hashable, Sendable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }

    /// Segment label in the period picker.
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// Supporting copy shown under the headline.
    var caption: String {
        switch self {
        case .today: "Today so far"
        case .week: "Rolling 7 days"
        case .month: "Rolling 30 days"
        }
    }

    /// How many days the window spans, including today.
    var dayCount: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    /// Comparison copy used in trend accessibility labels.
    var comparisonCaption: String {
        switch self {
        case .today: "vs yesterday"
        case .week: "vs previous 7 days"
        case .month: "vs previous 30 days"
        }
    }

    /// The reporting window: `[start of the first day, start of tomorrow)`.
    func range(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let today = now.startOfDay(in: calendar)
        let start = today.adding(days: -(dayCount - 1), calendar: calendar)
        let end = today.adding(days: 1, calendar: calendar)
        return DateInterval(start: start, end: end)
    }

    /// The equally sized window immediately before ``range(now:calendar:)``,
    /// used to compute every KPI trend.
    func previousRange(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let current = range(now: now, calendar: calendar)
        let start = current.start.adding(days: -dayCount, calendar: calendar)
        return DateInterval(start: start, end: current.start)
    }
}

// MARK: - Formatting

/// Number and date formatting shared by the dashboard and analytics screens.
/// Everything is locale-aware and Dynamic Type friendly (short strings, no
/// hand-built padding).
enum DashboardFormat {
    /// A compact currency string for tiles: `€1.2k`, `€1.4M`, `€860.00`.
    static func compactCurrency(_ money: Money) -> String {
        compactCurrency(money.amount.doubleValue, currency: money.currency)
    }

    /// A compact currency string from a raw amount.
    static func compactCurrency(_ value: Double, currency: Currency) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000 {
            let scaled = magnitude / 1_000_000
            return "\(sign)\(currency.symbol)\(scaled.formatted(.number.precision(.fractionLength(0...1))))M"
        }
        if magnitude >= 10_000 {
            let scaled = magnitude / 1_000
            return "\(sign)\(currency.symbol)\(scaled.formatted(.number.precision(.fractionLength(0...1))))k"
        }
        return value.formatted(.currency(code: currency.rawValue))
    }

    /// A full currency string, e.g. `€1,284.00`.
    static func currency(_ value: Double, currency: Currency) -> String {
        value.formatted(.currency(code: currency.rawValue))
    }

    /// A whole-number percentage from a 0…1 fraction, e.g. `78%`.
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// A one-decimal percentage from a 0…1 fraction, e.g. `6.4%`.
    static func precisePercent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }

    /// A grouped integer, e.g. `1,204`.
    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Short day label used on chart axes, e.g. `Mon 4`.
    static func axisDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// Time-of-day label for the appointment timeline, e.g. `14:00`.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Hour-of-day label for the occupancy heatmap, e.g. `14`.
    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d", hour)
    }

    /// Inclusive, human range title, e.g. `1 Jul – 31 Jul 2026`.
    static func rangeTitle(_ interval: DateInterval, calendar: Calendar = .current) -> String {
        let lastDay = interval.end.adding(days: -1, calendar: calendar)
        if interval.start.isSameDay(as: lastDay, calendar: calendar) {
            return interval.start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(lastDay.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Copy

/// Warm, actionable failure copy. Business users never see transport codes.
enum DashboardCopy {
    /// Maps any repository error to one short sentence with a next step.
    nonisolated static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Your last figures are shown — pull to refresh once you reconnect."
        case .rateLimited:
            "Reports are catching up. Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "You don't have access to these reports. Ask an owner to update your permissions."
        case .notFound, .conflict, .server, .decoding:
            "We couldn't build this report right now. Pull to refresh to try again."
        }
    }
}

// MARK: - Section chrome

/// A titled dashboard section: header, optional caption, and content.
/// Keeps vertical rhythm identical across every block on the screen.
struct DashboardSection<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(title, subtitle: subtitle)
            content
        }
    }
}

/// A compact inline failure card for a single section, with a retry.
struct DashboardErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)

            Text(message)
                .prvStyle(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: PRVSpacing.xs)

            Button("Retry") {
                PRVHaptics.tap()
                retry()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.prv.accent)
            .buttonStyle(.plain)
            .accessibilityLabel("Retry loading this section")
        }
        .prvGlassCard()
    }
}

/// A caption explaining how a modelled figure was derived. Used wherever the
/// dashboard projects a distribution rather than reading per-slot telemetry.
struct DashboardFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xxs) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(Color.prv.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview session

extension UserSession {
    /// Preview session for an owner who runs several locations, so the
    /// `.compareLocations`-gated roll-up can be exercised in previews.
    /// `UserSession.previewOwner` is a single-salon owner and never sees it.
    static var previewMultiSalonOwner: UserSession {
        UserSession(
            currentUser: User(
                id: User.ID("00000000-0000-0000-0000-00000000000A"),
                role: .multiSalonOwner,
                firstName: "Camille",
                lastName: "Deroo",
                email: "camille@maisonlumiere.be",
                salonIDs: [PreviewData.salonLumiere.id, PreviewData.salonVelvet.id]
            )
        )
    }
}

// MARK: - Skeletons

/// Shimmering placeholder for the KPI grid and the first chart, shown only on
/// the very first load — refreshes keep the previous figures on screen.
struct DashboardSkeleton: View {
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 148), spacing: PRVSpacing.sm)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            LazyVGrid(columns: columns, spacing: PRVSpacing.sm) {
                ForEach(0 ..< 6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        PRVSkeleton(width: 80, height: 11)
                        PRVSkeleton(width: 110, height: 24)
                        PRVSkeleton(width: 60, height: 11)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .prvGlassCard()
                }
            }

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSkeleton(width: 160, height: 20)
                PRVSkeleton(height: 200, radius: PRVRadius.lg)
            }

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSkeleton(width: 190, height: 20)
                ForEach(0 ..< 3, id: \.self) { _ in
                    HStack(spacing: PRVSpacing.sm) {
                        PRVSkeleton(width: 52, height: 44, radius: PRVRadius.sm)
                        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                            PRVSkeleton(width: 150, height: 14)
                            PRVSkeleton(width: 100, height: 11)
                        }
                        Spacer()
                    }
                    .prvGlassCard()
                }
            }
        }
        .accessibilityLabel("Loading your dashboard")
    }
}
