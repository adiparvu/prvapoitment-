import Foundation
import Observation
import PRVBookingKit
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// A sheet raised from an appointment card.
struct AppointmentSheetRoute: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case reschedule
        case cancel
    }

    var kind: Kind
    var appointment: Appointment

    var id: String { "\(kind.rawValue)-\(appointment.id.description)" }
}

/// The two segments of the bookings list.
enum AppointmentScope: String, CaseIterable, Hashable, Sendable, Identifiable {
    case upcoming = "Upcoming"
    case past = "Past"

    var id: String { rawValue }
}

/// Screen model backing ``AppointmentsListView``.
///
/// Loads the client's appointments together with the orders, invoices, and
/// salons they reference, so every card can show its status, its money, and
/// its cancellation terms without a second round trip.
@Observable
@MainActor
final class AppointmentsListModel {
    /// Lifecycle of the list load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var appointments: [Appointment] = []
    private(set) var salons: [Salon.ID: Salon] = [:]
    private(set) var ordersByAppointment: [Appointment.ID: Order] = [:]
    private(set) var invoicesByOrder: [Order.ID: Invoice] = [:]
    /// Appointments with a mutation in flight (cancel/reschedule).
    private(set) var busyAppointmentIDs: Set<Appointment.ID> = []

    var scope: AppointmentScope = .upcoming
    var sheet: AppointmentSheetRoute?
    /// The appointment a swipe-to-cancel is asking about. Bound to the list's
    /// `.confirmationDialog(item:)`, so the prompt and its subject are a single
    /// piece of state and a stray swipe can never cancel a visit on its own.
    var appointmentPendingCancellation: Appointment?
    var toast: PRVToast?

    /// Deterministic fee/refund rules shared with the server.
    private let cancellationEngine = CancellationEngine()

    /// Creates an empty list model; call ``load(for:using:)`` to populate it.
    init() {}

    // MARK: - Loading

    /// Loads appointments plus the orders, invoices, and salons they need.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            appointments = []
            phase = .loaded
            return
        }
        if appointments.isEmpty { phase = .loading }
        do {
            async let appointmentsTask = deps.appointments.appointments(clientID: user.id)
            async let ordersTask = deps.payments.orders(clientID: user.id)
            async let invoicesTask = deps.payments.invoices(userID: user.id)

            let loadedAppointments = try await appointmentsTask
            let loadedOrders = try await ordersTask
            let loadedInvoices = try await invoicesTask

            appointments = loadedAppointments
            ordersByAppointment = Dictionary(
                loadedOrders.compactMap { order in order.appointmentID.map { ($0, order) } },
                uniquingKeysWith: { _, newest in newest }
            )
            invoicesByOrder = Dictionary(
                loadedInvoices.map { ($0.orderID, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            await loadSalons(for: loadedAppointments, using: deps)
            phase = .loaded
        } catch {
            PRVLog.booking.error("Appointments load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(BookingFormatting.friendlyError(error, subject: "Your bookings"))
        }
    }

    /// Fetches every salon referenced by the appointments, concurrently.
    private func loadSalons(for appointments: [Appointment], using deps: PRVDependencies) async {
        let repository = deps.salons
        let ids = Set(appointments.map(\.salonID)).subtracting(salons.keys)
        guard !ids.isEmpty else { return }
        var loaded = salons
        await withTaskGroup(of: Salon?.self) { group in
            for id in ids {
                group.addTask { try? await repository.salon(id: id) }
            }
            for await salon in group {
                if let salon { loaded[salon.id] = salon }
            }
        }
        salons = loaded
    }

    // MARK: - Derived data

    /// Active appointments that have not finished yet, soonest first.
    var upcoming: [Appointment] {
        appointments
            .filter { $0.status.isActive && ($0.end ?? .distantPast) >= .now }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Finished, cancelled, and missed appointments, most recent first.
    var past: [Appointment] {
        appointments
            .filter { !$0.status.isActive || ($0.end ?? .distantPast) < .now }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    /// The appointments shown by the current segment.
    var visibleAppointments: [Appointment] {
        scope == .upcoming ? upcoming : past
    }

    /// The salon an appointment belongs to, once loaded.
    func salon(for appointment: Appointment) -> Salon? {
        salons[appointment.salonID]
    }

    /// The order paying for an appointment, if one exists.
    func order(for appointment: Appointment) -> Order? {
        ordersByAppointment[appointment.id]
    }

    /// The invoice issued for an appointment's order, if one exists.
    func invoice(for appointment: Appointment) -> Invoice? {
        order(for: appointment).flatMap { invoicesByOrder[$0.id] }
    }

    /// Whether a mutation is in flight for this appointment.
    func isBusy(_ appointment: Appointment) -> Bool {
        busyAppointmentIDs.contains(appointment.id)
    }

    /// What the client has already paid toward an appointment.
    func amountPaid(for appointment: Appointment) -> Money {
        order(for: appointment)?.amountPaid ?? .zero(appointment.totalPrice.currency)
    }

    /// What cancelling this appointment would cost right now, straight from the
    /// booking kit's cancellation engine.
    func cancellationAssessment(for appointment: Appointment) -> CancellationAssessment {
        cancellationEngine.assess(
            policies: salon(for: appointment)?.policies ?? SalonPolicies(),
            appointmentStart: appointment.start ?? .now,
            now: .now,
            amountPaid: amountPaid(for: appointment),
            trigger: .clientCancellation
        )
    }

    /// Service identifiers to rebook from a past visit.
    func serviceIDs(of appointment: Appointment) -> [SalonService.ID] {
        appointment.items.map(\.serviceID)
    }

    // MARK: - Mutations

    /// Cancels an appointment after the client confirmed the assessed fee.
    /// Returns `true` on success so the sheet can dismiss.
    @discardableResult
    func cancel(_ appointment: Appointment, reason: String?, using deps: PRVDependencies) async -> Bool {
        busyAppointmentIDs.insert(appointment.id)
        defer { busyAppointmentIDs.remove(appointment.id) }
        do {
            let updated = try await deps.appointments.cancel(
                appointmentID: appointment.id,
                reason: reason
            )
            replace(updated)
            toast = .success("Your appointment has been cancelled.")
            PRVHaptics.success()
            return true
        } catch {
            PRVLog.booking.error("Cancellation failed: \(String(describing: error), privacy: .public)")
            toast = .error(BookingFormatting.friendlyError(error, subject: "This appointment"))
            PRVHaptics.error()
            return false
        }
    }

    /// Moves an appointment to a new slot. Returns `true` on success.
    @discardableResult
    func reschedule(_ appointment: Appointment, to slot: TimeSlot, using deps: PRVDependencies) async -> Bool {
        busyAppointmentIDs.insert(appointment.id)
        defer { busyAppointmentIDs.remove(appointment.id) }
        do {
            let updated = try await deps.appointments.reschedule(
                appointmentID: appointment.id,
                to: slot
            )
            replace(updated)
            toast = .success("Moved to \(BookingFormatting.dateAndTime(slot.start)).")
            PRVHaptics.success()
            return true
        } catch {
            PRVLog.booking.error("Reschedule failed: \(String(describing: error), privacy: .public)")
            toast = .error(BookingFormatting.friendlyError(error, subject: "That time slot"))
            PRVHaptics.error()
            return false
        }
    }

    /// Finds the client's conversation with a salon, so the card can open it.
    func conversationID(
        withSalon salonID: Salon.ID,
        userID: User.ID,
        using deps: PRVDependencies
    ) async -> Conversation.ID? {
        do {
            let conversations = try await deps.chat.conversations(userID: userID)
            return conversations.first { $0.salonID == salonID }?.id
        } catch {
            PRVLog.booking.info("Conversation lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func replace(_ appointment: Appointment) {
        if let index = appointments.firstIndex(where: { $0.id == appointment.id }) {
            appointments[index] = appointment
        } else {
            appointments.append(appointment)
        }
    }
}
