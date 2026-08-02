import SwiftUI
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The salon's day book — the business Calendar tab.
///
/// Reads the *salon's* schedule for the selected day through
/// `AppointmentRepository.appointments(salonID:on:)`, scoped to
/// `UserSession.activeSalonID`, so an owner or manager sees the studio's
/// bookings rather than their own personal ones. Tapping a booking pushes the
/// shared `.appointment` route.
struct SalonScheduleView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model: SalonScheduleModel

    /// Creates the schedule.
    /// - Parameter day: The day initially shown. Defaults to today.
    init(day: Date = .now) {
        _model = State(initialValue: SalonScheduleModel(day: day))
    }

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: PRVSpacing.md) {
                PRVDateStrip(
                    selection: $model.day,
                    startingFrom: Date.now.adding(days: -7),
                    days: 35
                )

                VStack(spacing: PRVSpacing.md) {
                    summary
                    content
                }
                .padding(.horizontal, PRVSpacing.md)
            }
            .padding(.top, PRVSpacing.xs)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Calendar")
        .refreshable { await refresh() }
        .task(id: taskIdentity) { await refresh() }
        .prvAnimation(PRVMotion.spring, value: model.day)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
    }

    // MARK: - Summary

    /// The day at a glance: how much of it is still to come, and what the book
    /// is worth.
    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.md) {
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(AppointmentFormat.day(model.day))
                    .prvStyle(.headline)
                Text(model.bookingsSummary)
                    .prvStyle(.footnote)
            }

            Spacer(minLength: PRVSpacing.sm)

            if let value = model.bookedValue {
                PRVPriceLabel(value.formatted, emphasis: .prominent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: PRVSpacing.sm) {
                ForEach(0..<3, id: \.self) { _ in
                    ScheduleRowSkeleton()
                }
            }
        case .failed(let message):
            AppointmentErrorCard(message: message) {
                Task { await refresh() }
            }
        case .loaded:
            if session.activeSalonID == nil {
                PRVEmptyState(
                    systemImage: "building.2",
                    title: "No salon selected",
                    message: "Pick the salon you're working from to see its day book here."
                )
            } else if model.appointments.isEmpty {
                PRVEmptyState(
                    systemImage: "calendar.badge.clock",
                    title: "Nothing booked",
                    message: "This day is wide open. New bookings land here the moment clients confirm them."
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.appointments.enumerated()), id: \.element.id) { index, appointment in
                        ScheduleRow(
                            appointment: appointment,
                            isLast: index == model.appointments.count - 1
                        ) {
                            PRVHaptics.tap()
                            router.push(.appointment(appointment.id))
                        }
                    }
                }
                .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
            }
        }
    }

    // MARK: - Actions

    /// Reloading is keyed on the salon in scope and the selected day, so
    /// switching either one refetches exactly once.
    private var taskIdentity: String {
        "\(session.activeSalonID?.description ?? "none")-\(model.day.timeIntervalSinceReferenceDate)"
    }

    private func refresh() async {
        await model.load(salonID: session.activeSalonID, using: deps)
    }
}

// MARK: - Rows

/// One booking on the day: a time rail tinted by status, the services and who
/// is delivering them, and the value of the visit.
private struct ScheduleRow: View {
    let appointment: Appointment
    let isLast: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                timeColumn
                rail
                details
            }
            .padding(.vertical, PRVSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the booking")
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(appointment.start.map(AppointmentFormat.time) ?? "--:--")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
            if let end = appointment.end {
                Text(AppointmentFormat.time(end))
                    .prvStyle(.caption)
                    .monospacedDigit()
            }
        }
        .frame(width: 58, alignment: .trailing)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(appointment.status.shellTint)
                .frame(width: 9, height: 9)
                .padding(.top, PRVSpacing.xxs)
            if !isLast {
                Rectangle()
                    .fill(Color.prv.separator)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                Text(AppointmentFormat.services(appointment))
                    .prvStyle(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(appointment.totalPrice.formatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
            }

            if let professionals = AppointmentFormat.professionals(appointment) {
                Text(professionals)
                    .prvStyle(.footnote)
                    .lineLimit(1)
            }

            AppointmentStatusPill(status: appointment.status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, isLast ? 0 : PRVSpacing.xs)
    }
}

/// Shimmering placeholder matching a schedule row's silhouette.
private struct ScheduleRowSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            PRVSkeleton(width: 46, height: 16)
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                PRVSkeleton(width: 180, height: 18)
                PRVSkeleton(width: 120, height: 14)
                PRVSkeleton(width: 90, height: 18, radius: 9)
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .accessibilityHidden(true)
    }
}

// MARK: - Model

/// Screen model behind ``SalonScheduleView``.
///
/// One salon, one day, one query: the schedule is deliberately narrow so the
/// business Calendar tab never reaches for client-scoped data.
@Observable
@MainActor
final class SalonScheduleModel {
    /// Lifecycle of the day's load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The day's bookings, earliest first.
    private(set) var appointments: [Appointment] = []

    /// Day being shown. Seeded at the start of the day; the date strip writes
    /// start-of-day values too, so the repository query stays day-aligned.
    var day: Date

    /// Creates the model for one day.
    init(day: Date = .now) {
        self.day = day.startOfDay()
    }

    // MARK: Derived

    /// Bookings on the selected day that still need something from the front
    /// desk (arrivals to check in, treatments to close out).
    var openCount: Int {
        appointments.count { $0.status.isActive }
    }

    /// One-line description of the book, e.g. `"6 bookings · 4 still open"`.
    var bookingsSummary: String {
        guard !appointments.isEmpty else { return "No bookings" }
        let bookings = appointments.count == 1 ? "1 booking" : "\(appointments.count) bookings"
        guard openCount > 0 else { return "\(bookings) · all wrapped up" }
        return "\(bookings) · \(openCount) still open"
    }

    /// Value on the book for the day, excluding cancellations and no-shows.
    /// Bookings priced in another currency are left out rather than mixed in.
    var bookedValue: Money? {
        let billable = appointments.filter { $0.status.isActive || $0.status == .completed }
        guard let first = billable.first else { return nil }
        let currency = first.totalPrice.currency
        return billable
            .dropFirst()
            .map(\.totalPrice)
            .filter { $0.currency == currency }
            .reduce(first.totalPrice, +)
    }

    // MARK: Loading

    /// Loads the selected day's book for one salon. Safe to call again to
    /// retry or refresh; a salon-less session simply shows the empty state.
    /// - Parameters:
    ///   - salonID: The salon in scope, from `UserSession.activeSalonID`.
    ///   - deps: Repository container from the environment.
    func load(salonID: Salon.ID?, using deps: PRVDependencies) async {
        guard let salonID else {
            appointments = []
            phase = .loaded
            return
        }

        if appointments.isEmpty { phase = .loading }

        do {
            appointments = try await deps.appointments
                .appointments(salonID: salonID, on: day)
                .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            phase = .loaded
        } catch {
            appointments = []
            phase = .failed(AppointmentFormat.friendlyMessage(for: error))
        }
    }
}

// MARK: - Previews

#Preview("Calendar — booked day") {
    NavigationStack {
        SalonScheduleView(day: Date.now.adding(days: 3))
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .calendar))
}

#Preview("Calendar — empty day") {
    NavigationStack {
        SalonScheduleView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .calendar))
    .preferredColorScheme(.dark)
}
