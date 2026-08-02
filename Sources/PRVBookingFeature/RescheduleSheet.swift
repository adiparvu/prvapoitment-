import SwiftUI
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// A standalone availability loader for screens outside the booking flow —
/// today the reschedule sheet. It speaks the same ``SlotsPhase`` language as
/// ``BookingFlowModel`` so both render slots through ``SlotBoardView``.
@Observable
@MainActor
final class SlotPickerModel {
    let salonID: Salon.ID
    let serviceIDs: [SalonService.ID]
    let professionalID: Professional.ID?

    var selectedDay: Date
    private(set) var phase: SlotsPhase = .idle
    private(set) var selectedSlot: TimeSlot?

    /// Creates a picker for one salon and set of services.
    init(
        salonID: Salon.ID,
        serviceIDs: [SalonService.ID],
        professionalID: Professional.ID? = nil,
        startingDay: Date = .now
    ) {
        self.salonID = salonID
        self.serviceIDs = serviceIDs
        self.professionalID = professionalID
        self.selectedDay = startingDay.startOfDay()
    }

    /// Identity of the current availability query, for `.task(id:)`.
    var requestKey: SlotRequestKey {
        SlotRequestKey(
            salonID: salonID,
            day: selectedDay.startOfDay(),
            professionalID: professionalID,
            serviceIDs: serviceIDs
        )
    }

    /// The three slots that fit the salon's calendar best.
    var recommendedSlots: [TimeSlot] {
        let slots = phase.slots
        guard slots.count > 3 else { return [] }
        return slots.topRecommended()
    }

    /// Loads bookable slots for the selected day.
    func load(using deps: PRVDependencies) async {
        guard !serviceIDs.isEmpty else {
            phase = .loaded([])
            return
        }
        phase = .loading
        let dayStart = selectedDay.startOfDay()
        let request = AvailabilityRequest(
            salonID: salonID,
            serviceIDs: serviceIDs,
            professionalID: professionalID,
            rangeStart: max(dayStart, .now),
            rangeEnd: dayStart.adding(days: 1).addingTimeInterval(-1)
        )
        do {
            let slots = try await deps.appointments.availableSlots(request)
                .filter { $0.start.isSameDay(as: dayStart) }
                .sorted { $0.start < $1.start }
            guard !Task.isCancelled else { return }
            phase = .loaded(slots)
            if let selectedSlot, !slots.contains(selectedSlot) {
                self.selectedSlot = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            PRVLog.booking.error("Reschedule availability failed: \(String(describing: error), privacy: .public)")
            phase = .failed(BookingFormatting.friendlyError(error, subject: "Availability"))
        }
    }

    /// Chooses a slot.
    func select(_ slot: TimeSlot) {
        selectedSlot = slot
    }
}

/// Moves an existing appointment to a new time, reusing the booking flow's
/// day strip and slot board so rescheduling feels like the step it mirrors.
struct RescheduleSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(\.dismiss) private var dismiss

    let appointment: Appointment
    /// Whether the reschedule request is in flight.
    let isSaving: Bool
    /// Commits the new slot. Returns `true` when the move succeeded.
    let confirm: @MainActor (TimeSlot) async -> Bool

    @State private var model: SlotPickerModel

    /// Creates the sheet for one appointment.
    init(
        appointment: Appointment,
        isSaving: Bool,
        confirm: @escaping @MainActor (TimeSlot) async -> Bool
    ) {
        self.appointment = appointment
        self.isSaving = isSaving
        self.confirm = confirm
        _model = State(initialValue: SlotPickerModel(
            salonID: appointment.salonID,
            serviceIDs: appointment.items.map(\.serviceID),
            professionalID: appointment.items.first?.professionalID,
            startingDay: appointment.start ?? .now
        ))
    }

    var body: some View {
        // A local bindable projection for the day strip's two-way binding.
        @Bindable var bindableModel = model

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    currentCard

                    PRVDateStrip(selection: $bindableModel.selectedDay, days: 30)
                        .padding(.horizontal, -PRVSpacing.md)

                    SlotBoardView(
                        phase: model.phase,
                        recommended: model.recommendedSlots,
                        selectedSlot: model.selectedSlot,
                        onSelect: { model.select($0) },
                        onRetry: { Task { await model.load(using: deps) } }
                    )
                }
                .padding(PRVSpacing.md)
                .padding(.bottom, PRVSpacing.xl)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PRVBottomBar {
                    VStack(spacing: PRVSpacing.xs) {
                        if let slot = model.selectedSlot {
                            Text("Moving to \(BookingFormatting.dateAndTime(slot.start))")
                                .prvStyle(.footnote)
                                .multilineTextAlignment(.center)
                        }
                        Button {
                            commit()
                        } label: {
                            if isSaving {
                                ProgressView().controlSize(.small).tint(Color.prv.textOnAccent)
                            } else {
                                Text("Confirm New Time")
                            }
                        }
                        .buttonStyle(.prvPrimary)
                        .disabled(model.selectedSlot == nil || isSaving)
                        .accessibilityLabel("Confirm new time")
                        .accessibilityHint(model.selectedSlot == nil ? "Choose a slot first" : "")
                    }
                }
            }
            .task(id: model.requestKey) {
                await model.load(using: deps)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// A reminder of where the appointment sits today.
    private var currentCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text(appointment.salonName)
                    .prvStyle(.headline)
                BookingSummaryRow(
                    label: "Currently",
                    value: appointment.start.map(BookingFormatting.dateAndTime) ?? "Unscheduled",
                    systemImage: "calendar"
                )
                BookingSummaryRow(
                    label: "Treatments",
                    value: appointment.items.map(\.serviceName).joined(separator: ", "),
                    systemImage: "sparkles"
                )
                if let professional = appointment.items.first?.professionalName {
                    BookingSummaryRow(
                        label: "Artist",
                        value: professional,
                        systemImage: "person.crop.circle"
                    )
                }
            }
        }
    }

    private func commit() {
        guard let slot = model.selectedSlot else { return }
        PRVHaptics.impact()
        Task {
            if await confirm(slot) {
                dismiss()
            }
        }
    }
}

#Preview("Reschedule") {
    RescheduleSheet(appointment: PreviewData.upcomingAppointment, isSaving: false) { _ in true }
        .environment(UserSession.previewClient)
        .environment(AppRouter(selectedTab: .appointments))
}
