import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// Studio-local chrome, formatting, and copy shared by the three operations
// desks. Everything here stays `internal` by module-ownership rules; promote
// to PRVDesignSystem only if another feature needs the same shapes.

// MARK: - Sections

/// The three desks of the studio operations hub.
///
/// ``TeamView`` is the hub root and switches between them; ``InventoryView``
/// and ``MarketingView`` are also usable standalone.
enum OperationsSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case team
    case inventory
    case marketing

    var id: String { rawValue }

    /// Segment label in the hub's header control.
    var title: String {
        switch self {
        case .team: "Team"
        case .inventory: "Inventory"
        case .marketing: "Marketing"
        }
    }

    /// SF Symbol used in empty states and navigation chrome.
    var symbolName: String {
        switch self {
        case .team: "person.2.badge.gearshape"
        case .inventory: "shippingbox"
        case .marketing: "megaphone"
        }
    }
}

// MARK: - Phase

/// Loading lifecycle of an operations desk.
///
/// One phase per desk: the first load renders skeletons, later refreshes keep
/// the previous content on screen so the studio never blinks mid-shift.
enum OperationsPhase: Equatable, Sendable {
    /// The first load is in flight; render skeletons.
    case loading
    /// Content is on screen (possibly refreshing in the background).
    case loaded
    /// The load failed with human-readable copy.
    case failed(String)

    /// Whether the desk is still waiting for its first payload.
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Copy

/// Warm, actionable failure copy. Studio staff never see transport codes.
enum OperationsCopy {
    /// Maps a repository error to one sentence with a next step.
    /// - Parameters:
    ///   - error: The thrown error.
    ///   - subject: What failed to load, lowercase, e.g. `"your team"`.
    nonisolated static func loadMessage(for error: any Error, subject: String) -> String {
        guard let apiError = error as? APIError else {
            return "We couldn't load \(subject) right now. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. The last copy of \(subject) is shown — pull to refresh once you reconnect."
        case .rateLimited:
            "We're catching up on \(subject). Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "You don't have access to \(subject). Ask an owner to update your permissions."
        case .notFound, .conflict, .server, .decoding:
            "We couldn't load \(subject) right now. Pull to refresh to try again."
        }
    }

    /// Maps a failed mutation to one sentence. Used for toasts after a save.
    nonisolated static func saveMessage(for error: any Error, action: String) -> String {
        guard let apiError = error as? APIError else {
            return "We couldn't \(action). Try again in a moment."
        }
        return switch apiError {
        case .offline, .network:
            "You're offline — we couldn't \(action). It will need a connection."
        case .rateLimited:
            "Too many changes at once. Wait a moment, then \(action) again."
        case .unauthorized, .forbidden:
            "You don't have permission to \(action)."
        case .conflict(let message):
            message.isBlank ? "Someone else changed this first. Refresh and \(action) again." : message
        case .notFound:
            "That record no longer exists. Refresh and try again."
        case .server, .decoding:
            "We couldn't \(action). Try again in a moment."
        }
    }
}

// MARK: - Formatting

/// Number, date, and duration formatting shared by the three desks.
/// Everything is locale-aware and Dynamic Type friendly.
enum OperationsFormat {
    /// A full currency string from a raw amount, e.g. `€1,284.00`.
    static func currency(_ value: Decimal, _ currency: Currency) -> String {
        value.doubleValue.formatted(.currency(code: currency.rawValue))
    }

    /// A compact currency string for tiles: `€1.2k`, `€1.4M`, `€860.00`.
    static func compactCurrency(_ money: Money) -> String {
        let value = money.amount.doubleValue
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000 {
            let scaled = magnitude / 1_000_000
            return "\(sign)\(money.currency.symbol)\(scaled.formatted(.number.precision(.fractionLength(0...1))))M"
        }
        if magnitude >= 10_000 {
            let scaled = magnitude / 1_000
            return "\(sign)\(money.currency.symbol)\(scaled.formatted(.number.precision(.fractionLength(0...1))))k"
        }
        return value.formatted(.currency(code: money.currency.rawValue))
    }

    /// A whole-number percentage from a 0…1 fraction, e.g. `78%`.
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// A grouped integer, e.g. `1,204`.
    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A decimal rendered plainly, e.g. `4.8`.
    static func decimal(_ value: Decimal, fractionDigits: Int = 0) -> String {
        value.doubleValue.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// Time of day, e.g. `09:30`.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// A shift window, e.g. `09:30 – 17:00`.
    static func window(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// Weekday + day number, e.g. `Mon 4`.
    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// Full day, e.g. `Monday 4 August`.
    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Abbreviated date, e.g. `4 Aug 2026`.
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Abbreviated date and time, e.g. `4 Aug, 09:30`.
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// A worked duration in hours and minutes, e.g. `7h 30m`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// A running stopwatch value, e.g. `3:12:04`. Monospaced-digit friendly.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// Decimal hours for payroll math, e.g. `37.5 h`.
    static func hours(_ seconds: TimeInterval) -> String {
        "\((seconds / 3_600).formatted(.number.precision(.fractionLength(0...1)))) h"
    }

    /// Inclusive range title, e.g. `1 Aug – 7 Aug 2026`.
    static func rangeTitle(_ interval: DateInterval, calendar: Calendar = .current) -> String {
        let lastDay = interval.end.adding(days: -1, calendar: calendar)
        if interval.start.isSameDay(as: lastDay, calendar: calendar) {
            return date(interval.start)
        }
        return "\(date(interval.start)) – \(date(lastDay))"
    }

    /// Relative day copy for expiry and schedule captions, e.g. `in 12 days`.
    static func relativeDays(_ days: Int) -> String {
        switch days {
        case ..<0: "\(abs(days))d ago"
        case 0: "today"
        case 1: "tomorrow"
        default: "in \(days)d"
        }
    }
}

// MARK: - Section chrome

/// A titled block inside a desk: header, optional caption, optional trailing
/// action, and content. Keeps vertical rhythm identical across the hub.
struct OperationsBlock<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(title, subtitle: subtitle, actionTitle: actionTitle, action: action)
            content
        }
    }
}

/// A compact inline failure card for a single block, with a retry.
struct OperationsErrorCard: View {
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

/// A caption explaining how a modelled figure was derived, or what a control
/// will do. Used wherever the hub estimates rather than reports.
struct OperationsFootnote: View {
    private let text: String
    private let systemImage: String

    init(_ text: String, systemImage: String = "info.circle") {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xxs) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(Color.prv.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A small status capsule (purchase-order status, campaign status).
struct OperationsStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.vertical, 3)
            .padding(.horizontal, PRVSpacing.xs)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay { Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5) }
            .accessibilityLabel("Status: \(title)")
    }
}

/// A label + value line used inside detail cards and sheets.
struct OperationsDetailRow: View {
    let label: String
    let value: String
    var systemImage: String?
    var tint: Color = Color.prv.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(Color.prv.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(label)
                .prvStyle(.subheadline)
            Spacer(minLength: PRVSpacing.xs)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A horizontal capacity bar (vacation used, coupon redemptions, PO progress).
struct OperationsMeter: View {
    /// Completion fraction, clamped to 0…1.
    let fraction: Double
    var tint: AnyShapeStyle = AnyShapeStyle(Color.prv.accentGradient)
    var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(Color.prv.separator.opacity(0.35))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, proxy.size.width * clamped))
                }
            }
            .prvAnimation(PRVMotion.gentle, value: clamped)
            .accessibilityHidden(true)
    }

    private var clamped: Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }
}

// MARK: - Swipe to delete

/// A swipe-to-delete row that works inside a `ScrollView` (SwiftUI's built-in
/// `swipeActions` needs a `List`, which would fight the hub's card layout).
///
/// Dragging left reveals a destructive button; VoiceOver users get the same
/// action through an accessibility custom action, and everyone gets it through
/// the row's context menu.
struct OperationsSwipeRow<Content: View>: View {
    private let deleteLabel: String
    private let onDelete: () -> Void
    private let onTap: (() -> Void)?
    private let content: Content

    @State private var offset: CGFloat = 0

    private let actionWidth: CGFloat = 84

    /// Creates a swipeable row.
    /// - Parameters:
    ///   - deleteLabel: Accessible name for the destructive action.
    ///   - onDelete: Performed when the destructive button is tapped.
    ///   - onTap: Performed when the closed row is tapped. A tap on an open
    ///     row always closes it instead, so the destructive action can't be
    ///     triggered by a stray tap.
    ///   - content: The row itself; it gets an opaque surface so the action
    ///     stays hidden until revealed.
    init(
        deleteLabel: String = "Delete",
        onDelete: @escaping () -> Void,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.deleteLabel = deleteLabel
        self.onDelete = onDelete
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                PRVHaptics.warning()
                close()
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.prv.textOnAccent)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.prv.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(deleteLabel)
            .opacity(offset < -2 ? 1 : 0)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PRVSpacing.sm)
                .background(Color.prv.surfaceElevated)
                .contentShape(Rectangle())
                .offset(x: offset)
                .gesture(drag)
                .onTapGesture {
                    if offset != 0 {
                        close()
                    } else if let onTap {
                        PRVHaptics.tap()
                        onTap()
                    }
                }
        }
        .clipShape(PRVRadius.shape(PRVRadius.md))
        .prvAnimation(PRVMotion.spring, value: offset)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(deleteLabel)) {
            PRVHaptics.warning()
            onDelete()
        }
        .contextMenu {
            Button(role: .destructive) {
                PRVHaptics.warning()
                onDelete()
            } label: {
                Label(deleteLabel, systemImage: "trash")
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, max(-actionWidth, value.translation.width))
            }
            .onEnded { value in
                let shouldOpen = value.translation.width < -actionWidth / 2
                    || value.predictedEndTranslation.width < -actionWidth
                if shouldOpen {
                    PRVHaptics.tap()
                    offset = -actionWidth
                } else {
                    close()
                }
            }
    }

    private func close() {
        offset = 0
    }
}

// MARK: - Skeletons

/// Shimmering placeholder used while a desk loads for the first time.
struct OperationsSkeleton: View {
    /// How many card rows to draw.
    var rows: Int = 4
    /// Whether to lead with a tile grid (used by inventory and marketing).
    var showsTiles: Bool = true
    /// Announced to VoiceOver while the desk loads.
    var label: String = "Loading"

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: PRVSpacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            if showsTiles {
                LazyVGrid(columns: columns, spacing: PRVSpacing.sm) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                            PRVSkeleton(width: 78, height: 11)
                            PRVSkeleton(width: 104, height: 24)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .prvGlassCard()
                    }
                }
            }

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSkeleton(width: 168, height: 20)
                ForEach(0 ..< max(1, rows), id: \.self) { _ in
                    HStack(spacing: PRVSpacing.sm) {
                        PRVSkeleton(width: 48, height: 48, radius: PRVRadius.md)
                        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                            PRVSkeleton(width: 152, height: 14)
                            PRVSkeleton(width: 96, height: 11)
                        }
                        Spacer()
                        PRVSkeleton(width: 56, height: 22, radius: PRVRadius.sm)
                    }
                    .prvGlassCard()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// MARK: - Navigation chrome

/// Applies a large navigation title only when the desk is running standalone.
///
/// ``InventoryView`` and ``MarketingView`` are embedded inside ``TeamView``'s
/// hub, and a title set on a descendant would override the hub's own — so when
/// embedded they set none at all.
private struct OperationsNavigationTitle: ViewModifier {
    let title: String
    let isEmbedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
        }
    }
}

extension View {
    /// Titles a desk when it is presented on its own.
    func operationsNavigationTitle(_ title: String, isEmbedded: Bool) -> some View {
        modifier(OperationsNavigationTitle(title: title, isEmbedded: isEmbedded))
    }
}

// MARK: - Preview session

extension UserSession {
    /// Preview session for a stylist on the floor: they can clock in and read
    /// the roster, but hold none of the management permissions, so previews can
    /// exercise every locked state in the hub.
    static var previewSalonEmployee: UserSession {
        UserSession(
            currentUser: User(
                id: User.ID("00000000-0000-0000-0000-00000000000B"),
                role: .salonEmployee,
                firstName: "Amélie",
                lastName: "Dubois",
                email: "amelie@maisonlumiere.be",
                salonIDs: [PreviewData.salonLumiere.id]
            )
        )
    }
}

// MARK: - Permission notice

/// Shown in place of a privileged block when the session lacks the permission.
struct OperationsLockedNotice: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: "lock.fill")
                .font(.body)
                .foregroundStyle(Color.prv.textSecondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(message)
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .prvGlassCard()
        .accessibilityElement(children: .combine)
    }
}
