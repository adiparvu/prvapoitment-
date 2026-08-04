import Foundation
import PRVFoundation
import PRVModels

/// The live ``AppointmentRepository``.
///
/// Every read joins `appointments` with its `appointment_items` in one PostgREST
/// round trip. Every write that moves money or holds a chair goes through the
/// server-side path that owns those rules:
///
/// | Operation | Path | Why |
/// |---|---|---|
/// | `book` | `confirm-booking` → `book_appointment(jsonb)` | Advisory lock + `SELECT … FOR UPDATE` + exclusion constraint, all in one transaction |
/// | `cancel` | `cancel-appointment` Edge Function | Fee and refund rules stay server-authoritative |
/// | `updateStatus` | `PATCH appointments` | Trigger re-derives `is_blocking`, freeing a cancelled slot |
///
/// Nothing here ever inserts an appointment row directly: the overlap check lives
/// inside the transaction that writes the items, and a client-side check would be
/// a check performed before the write — precisely the race that double-books.
public struct SupabaseAppointmentRepository: AppointmentRepository {
    /// Which server-side entry point ``book(_:)`` uses.
    ///
    /// Both end in the same transactional `book_appointment` RPC; they differ in
    /// what happens around it.
    public enum BookingWritePath: Hashable, Sendable {
        /// Invoke `confirm-booking`, which calls `book_appointment` and then
        /// creates the order, applies the coupon, and fans out notifications.
        /// This is what the function's own contract documents as the write path
        /// for `AppointmentRepository.book(_:)`.
        case confirmBookingFunction
        /// Call `book_appointment` directly through PostgREST. Holds the slot
        /// with identical guarantees, but leaves the order, the coupon
        /// redemption, and the notifications for the caller. Use this when the
        /// Edge Functions are not deployed.
        case bookAppointmentRPC
    }

    private let client: SupabaseClient
    private let writePath: BookingWritePath

    /// The join every appointment read uses.
    private static let appointmentColumns = "*,appointment_items(*)"
    /// Statuses that occupy a chair — the same list the schema's partial index and
    /// `sync_appointment_item_blocking` use.
    private static let activeStatuses = [
        "pending_confirmation", "confirmed", "checked_in", "in_progress",
    ]
    /// Minutes between candidate slot starts, matching `InMemoryBackend`.
    private static let slotStrideMinutes = 45
    /// Upper bound on generated slots, matching `InMemoryBackend`.
    private static let slotLimit = 120

    /// Creates the repository.
    ///
    /// - Parameters:
    ///   - client: The shared Supabase transport.
    ///   - writePath: How bookings reach the database. See ``BookingWritePath``.
    public init(client: SupabaseClient, writePath: BookingWritePath = .confirmBookingFunction) {
        self.client = client
        self.writePath = writePath
    }

    // MARK: - Reads

    /// Every appointment a client participates in, earliest first.
    ///
    /// Group bookings put the other guests in `additional_client_ids`, so the
    /// filter is a disjunction of "I booked it" and "I am on it".
    public func appointments(clientID: User.ID) async throws -> [Appointment] {
        let request = PostgRESTQuery("appointments")
            .selecting(Self.appointmentColumns)
            .filter(.any(of: [
                .equals("client_id", clientID.rawValue),
                .containsAll("additional_client_ids", [clientID.rawValue.uuidString.lowercased()]),
            ]))
            .order("starts_at", nullsFirst: true)
            .limited(to: 200)
        let rows: [AppointmentRow] = try await client.select(request)
        return try rows.map(Self.makeAppointment)
    }

    /// One salon's calendar for one day, in the device's time zone.
    public func appointments(salonID: Salon.ID, on day: Date) async throws -> [Appointment] {
        let start = day.startOfDay()
        let end = start.adding(days: 1)
        let request = PostgRESTQuery("appointments")
            .selecting(Self.appointmentColumns)
            .filter(.equals("salon_id", salonID.rawValue))
            .filter(.atLeast("starts_at", SupabaseTimestamp.string(from: start)))
            .filter(.lessThan("starts_at", SupabaseTimestamp.string(from: end)))
            .order("starts_at", nullsFirst: true)
            .limited(to: 500)
        let rows: [AppointmentRow] = try await client.select(request)
        return try rows.map(Self.makeAppointment)
    }

    /// One appointment with its items.
    public func appointment(id: Appointment.ID) async throws -> Appointment {
        let request = PostgRESTQuery("appointments")
            .selecting(Self.appointmentColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: AppointmentRow = try await client.select(request)
        return try Self.makeAppointment(row)
    }

    // MARK: - Availability

    /// Bookable slots for a request.
    ///
    /// The schema exposes no availability RPC and no busy-times view — the only
    /// scheduling function in `0003_functions_triggers.sql` is `book_appointment`
    /// — so the slots are laid out here from three server reads: the salon's
    /// `salon_opening_hours`, the requested `services` (for chair time), and the
    /// active appointments overlapping the window.
    ///
    /// Two consequences worth knowing:
    ///
    /// 1. `appointments_select_participant` only lets a *client* see their own
    ///    bookings, so for a client this list is advisory: it is filtered by the
    ///    salon's opening hours and by that client's own calendar, and the
    ///    authoritative overlap check happens inside `book_appointment`, which
    ///    answers a taken slot with `APIError.conflict`. For salon staff — who may
    ///    read the whole salon's calendar — the list is exact. Making it exact for
    ///    clients needs a `SECURITY DEFINER` RPC that returns busy *intervals*
    ///    without the identities attached.
    /// 2. Feature code that already depends on `PRVBookingKit` should prefer
    ///    `AvailabilityEngine`, which additionally models per-professional
    ///    capacity and lead times. `PRVNetworking` cannot import a Kit
    ///    (`ARCHITECTURE.md` §3), so this is the schema-faithful equivalent of
    ///    `InMemoryBackend.availableSlots(_:)`: same 45-minute stride, same
    ///    occupancy arithmetic, same gap-filling score, real opening hours.
    public func availableSlots(_ request: AvailabilityRequest) async throws -> [TimeSlot] {
        async let hoursTask = openingHours(salonID: request.salonID)
        async let servicesTask = serviceSpans(ids: request.serviceIDs)
        async let busyTask = busyBlocks(
            salonID: request.salonID,
            from: request.rangeStart.startOfDay(),
            to: request.rangeEnd.startOfDay().adding(days: 1)
        )

        let hours = try await hoursTask
        let services = try await servicesTask
        let busy = try await busyTask

        let totalMinutes = max(30, services.reduce(0) { $0 + $1.occupancyMinutes })
        return Self.layOutSlots(
            request: request,
            openingHours: hours,
            totalMinutes: totalMinutes,
            busy: busy
        )
    }

    // MARK: - Writes

    /// Books an appointment.
    ///
    /// The slot is held by `book_appointment`, which takes an advisory lock on the
    /// professional, locks any overlapping item `FOR UPDATE`, and relies on the
    /// `appointment_items_no_overlap` exclusion constraint as the final arbiter —
    /// all inside one transaction. A lost race surfaces as `APIError.conflict`
    /// carrying the server's message (SQLSTATE `PRV09`), which is the signal to
    /// refresh availability rather than to retry blindly.
    public func book(_ request: BookingRequest) async throws -> Appointment {
        switch writePath {
        case .confirmBookingFunction:
            return try await client.invoke(
                function: "confirm-booking",
                body: request,
                as: Appointment.self
            )
        case .bookAppointmentRPC:
            return try await client.rpc(
                "book_appointment",
                params: BookAppointmentParams(pRequest: request),
                as: Appointment.self
            )
        }
    }

    /// Cancels an appointment through the `cancel-appointment` Edge Function.
    ///
    /// The function assesses the salon's cancellation policy, issues the Stripe
    /// refund, records it, updates the order, audits the action, and notifies both
    /// sides. None of that can happen on the device, so the client only asks.
    public func cancel(appointmentID: Appointment.ID, reason: String?) async throws -> Appointment {
        let response: CancelResponse = try await client.invoke(
            function: "cancel-appointment",
            body: CancelRequest(appointmentID: appointmentID.rawValue, reason: reason)
        )
        return response.appointment
    }

    /// Moves an appointment to a new slot, keeping its identity, order, and notes.
    ///
    /// Each item is shifted by the same offset, which is what preserves the gaps
    /// the salon built into the chain (preparation, cleanup, buffer). The items are
    /// written one PostgREST request at a time — later-first when moving forward,
    /// earlier-first when moving back — so a shifted item never lands on a sibling
    /// that has not moved yet and trips the exclusion constraint against its own
    /// appointment. A collision with *another* booking still surfaces as
    /// `APIError.conflict`, from the constraint itself.
    ///
    /// A single-statement `reschedule_appointment(p_appointment_id, p_start)` RPC
    /// would make this atomic; see the migration note in the handover.
    public func reschedule(appointmentID: Appointment.ID, to slot: TimeSlot) async throws -> Appointment {
        let spans: [ItemSpanRow] = try await client.select(
            PostgRESTQuery("appointment_items")
                .selecting("id,starts_at,ends_at")
                .filter(.equals("appointment_id", appointmentID.rawValue))
        )

        var moved: [ItemSpan] = []
        for span in spans {
            moved.append(ItemSpan(
                id: span.id,
                start: try SupabaseTimestamp.date(from: span.startsAt),
                end: try SupabaseTimestamp.date(from: span.endsAt)
            ))
        }

        if let earliest = moved.map({ $0.start }).min() {
            let offset = slot.start.timeIntervalSince(earliest)
            if offset != 0 {
                let ordered = offset > 0
                    ? moved.sorted { $0.start > $1.start }
                    : moved.sorted { $0.start < $1.start }
                for item in ordered {
                    _ = try await client.update(
                        "appointment_items",
                        values: ItemSpanUpdate(
                            startsAt: SupabaseTimestamp.string(from: item.start.addingTimeInterval(offset)),
                            endsAt: SupabaseTimestamp.string(from: item.end.addingTimeInterval(offset))
                        ),
                        filters: [.equals("id", item.id)],
                        returning: "id",
                        as: ItemIdentifierRow.self
                    )
                }
            }
        }

        return try await updateStatus(appointmentID: appointmentID, status: .confirmed)
    }

    /// Sets an appointment's status.
    ///
    /// Moving out of an active status makes the salon's slot immediately bookable
    /// again: `appointments_sync_blocking` clears `is_blocking` on the items, which
    /// is what takes them out of the exclusion constraint.
    public func updateStatus(
        appointmentID: Appointment.ID,
        status: AppointmentStatus
    ) async throws -> Appointment {
        let row: AppointmentRow = try await client.update(
            "appointments",
            values: AppointmentStatusUpdate(status: status.rawValue),
            filters: [.equals("id", appointmentID.rawValue)],
            returning: Self.appointmentColumns
        )
        return try Self.makeAppointment(row)
    }

    // MARK: - Waitlist

    /// Adds a client to a salon's waitlist.
    public func joinWaitlist(_ entry: WaitlistEntry) async throws -> WaitlistEntry {
        let payload = WaitlistInsert(
            id: entry.id.rawValue,
            salonID: entry.salonID.rawValue,
            clientID: entry.clientID.rawValue,
            serviceID: entry.serviceID.rawValue,
            professionalID: entry.professionalID?.rawValue,
            earliest: SupabaseTimestamp.string(from: entry.earliest),
            latest: SupabaseTimestamp.string(from: entry.latest),
            notified: entry.notified
        )
        let row: WaitlistRow = try await client.insert(into: "waitlist_entries", values: payload)
        return try Self.makeWaitlistEntry(row)
    }

    /// The salon's outstanding waitlist, earliest window first.
    ///
    /// Fulfilled entries are excluded: `WaitlistEntry` has no "fulfilled" state, so
    /// returning them would show a client as still waiting after they were seated.
    public func waitlist(salonID: Salon.ID) async throws -> [WaitlistEntry] {
        let request = PostgRESTQuery("waitlist_entries")
            .filter(.equals("salon_id", salonID.rawValue))
            .filter(.isNull("fulfilled_at"))
            .order("earliest")
            .limited(to: 200)
        let rows: [WaitlistRow] = try await client.select(request)
        return try rows.map(Self.makeWaitlistEntry)
    }

    // MARK: - Availability inputs

    private func openingHours(salonID: Salon.ID) async throws -> [OpeningHours] {
        let rows: [OpeningHoursRow] = try await client.select(
            PostgRESTQuery("salon_opening_hours")
                .selecting("weekday,open_minutes,close_minutes")
                .filter(.equals("salon_id", salonID.rawValue))
                .order("weekday")
                .order("open_minutes")
        )
        return Dictionary(grouping: rows) { $0.weekday }
            .map { weekday, group in
                OpeningHours(
                    weekday: weekday,
                    intervals: group
                        .sorted { $0.openMinutes < $1.openMinutes }
                        .map { OpeningHours.Interval(openMinutes: $0.openMinutes, closeMinutes: $0.closeMinutes) }
                )
            }
            .sorted { $0.weekday < $1.weekday }
    }

    private func serviceSpans(ids: [SalonService.ID]) async throws -> [ServiceSpanRow] {
        guard !ids.isEmpty else { return [] }
        let rows: [ServiceSpanRow] = try await client.select(
            PostgRESTQuery("services")
                .selecting("id,duration_minutes,preparation_minutes,cleanup_minutes")
                .filter(.within("id", ids.map(\.rawValue)))
        )
        // Preserve the order the client asked for; the chain is performed in it.
        return ids.compactMap { id in rows.first { $0.id == id.rawValue } }
    }

    private func busyBlocks(salonID: Salon.ID, from start: Date, to end: Date) async throws -> [BusyBlock] {
        let rows: [BusyRow] = try await client.select(
            PostgRESTQuery("appointments")
                .selecting("starts_at,ends_at,appointment_items(professional_id)")
                .filter(.equals("salon_id", salonID.rawValue))
                .filter(.within("status", Self.activeStatuses))
                .filter(.lessThan("starts_at", SupabaseTimestamp.string(from: end)))
                .filter(.greaterThan("ends_at", SupabaseTimestamp.string(from: start)))
                .limited(to: 500)
        )
        return rows.compactMap { row in
            guard let blockStart = SupabaseTimestamp.optionalDate(from: row.startsAt),
                  let blockEnd = SupabaseTimestamp.optionalDate(from: row.endsAt)
            else { return nil }
            let professionals = (row.appointmentItems?.values ?? []).compactMap { $0.professionalID }
            return BusyBlock(start: blockStart, end: blockEnd, professionalIDs: Set(professionals))
        }
    }

    // MARK: - Slot layout

    /// Walks the salon's opening hours and emits every free start.
    ///
    /// Mirrors `InMemoryBackend.availableSlots(_:)`: a 45-minute stride, the whole
    /// chain's chair time as the block length, a conflict test that ignores
    /// bookings for other professionals when a specific one was requested, and the
    /// same morning-adjacency score standing in for the gap-filling optimizer.
    private static func layOutSlots(
        request: AvailabilityRequest,
        openingHours: [OpeningHours],
        totalMinutes: Int,
        busy: [BusyBlock],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TimeSlot] {
        var slots: [TimeSlot] = []
        var day = request.rangeStart.startOfDay(in: calendar)
        let lastDay = request.rangeEnd.startOfDay(in: calendar)

        while day <= lastDay, slots.count < slotLimit {
            let weekday = calendar.component(.weekday, from: day)
            let intervals = openingHours.first { $0.weekday == weekday }?.intervals ?? []
            for interval in intervals where slots.count < slotLimit {
                var minute = interval.openMinutes
                while minute + totalMinutes <= interval.closeMinutes, slots.count < slotLimit {
                    defer { minute += slotStrideMinutes }
                    guard let start = calendar.date(byAdding: .minute, value: minute, to: day),
                          start > now,
                          start >= request.rangeStart,
                          start <= request.rangeEnd
                    else { continue }
                    let end = start.adding(minutes: totalMinutes, calendar: calendar)
                    let isTaken = busy.contains { block in
                        if let wanted = request.professionalID?.rawValue,
                           !block.professionalIDs.contains(wanted) {
                            return false
                        }
                        return start < block.end && end > block.start
                    }
                    guard !isTaken else { continue }
                    slots.append(TimeSlot(
                        start: start,
                        end: end,
                        professionalID: request.professionalID,
                        optimizationScore: 1.0 - abs(Double(minute) - 11 * 60) / (9 * 60)
                    ))
                }
            }
            day = day.adding(days: 1, calendar: calendar)
        }
        return slots
    }

    // MARK: - Row mapping

    private static func makeAppointment(_ row: AppointmentRow) throws -> Appointment {
        let items = try (row.appointmentItems?.values ?? [])
            .sorted { $0.position < $1.position }
            .map { item in
                AppointmentItem(
                    id: AppointmentItem.ID(item.id),
                    serviceID: SalonService.ID(item.serviceID),
                    serviceName: item.serviceName,
                    professionalID: item.professionalID.map { Professional.ID($0) },
                    professionalName: item.professionalName,
                    start: try SupabaseTimestamp.date(from: item.startsAt),
                    durationMinutes: item.durationMinutes,
                    price: Money(item.priceAmount, Currency(rawValue: item.priceCurrency.trimmed) ?? .eur),
                    addOnIDs: item.addOnIDs.map { ServiceAddOn.ID($0) }
                )
            }

        let recurrence = row.recurrenceFrequency
            .flatMap(RecurrenceRule.Frequency.init(rawValue:))
            .map { RecurrenceRule(frequency: $0, occurrences: row.recurrenceOccurrences) }

        return Appointment(
            id: Appointment.ID(row.id),
            salonID: Salon.ID(row.salonID),
            salonName: row.salonName,
            clientID: User.ID(row.clientID),
            additionalClientIDs: row.additionalClientIDs.map { User.ID($0) },
            items: items,
            status: AppointmentStatus(rawValue: row.status) ?? .pendingConfirmation,
            recurrence: recurrence,
            orderID: row.orderID.map { PRVID<Order>($0) },
            clientNotes: row.clientNotes,
            internalNotes: row.internalNotes,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt),
            updatedAt: try SupabaseTimestamp.date(from: row.updatedAt)
        )
    }

    private static func makeWaitlistEntry(_ row: WaitlistRow) throws -> WaitlistEntry {
        WaitlistEntry(
            id: WaitlistEntry.ID(row.id),
            salonID: Salon.ID(row.salonID),
            clientID: User.ID(row.clientID),
            serviceID: SalonService.ID(row.serviceID),
            professionalID: row.professionalID.map { Professional.ID($0) },
            earliest: try SupabaseTimestamp.date(from: row.earliest),
            latest: try SupabaseTimestamp.date(from: row.latest),
            createdAt: try SupabaseTimestamp.date(from: row.createdAt),
            notified: row.notified
        )
    }
}

// MARK: - Rows and payloads

extension SupabaseAppointmentRepository {
    /// A chair-time block already on the salon's calendar.
    fileprivate struct BusyBlock: Sendable {
        let start: Date
        let end: Date
        let professionalIDs: Set<UUID>
    }

    /// An `appointments` row joined with its items.
    fileprivate struct AppointmentRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let salonName: String
        let clientID: UUID
        let additionalClientIDs: [UUID]
        let status: String
        let recurrenceFrequency: String?
        let recurrenceOccurrences: Int?
        let orderID: UUID?
        let clientNotes: String?
        let internalNotes: String?
        let createdAt: String
        let updatedAt: String
        let appointmentItems: SupabaseEmbedded<AppointmentItemRow>?
    }

    /// An `appointment_items` row.
    fileprivate struct AppointmentItemRow: Decodable, Sendable {
        let id: UUID
        let serviceID: UUID
        let serviceName: String
        let professionalID: UUID?
        let professionalName: String?
        let startsAt: String
        let durationMinutes: Int
        let priceAmount: Decimal
        let priceCurrency: String
        let addOnIDs: [UUID]
        let position: Int
    }

    /// The span columns of one item, for rescheduling.
    fileprivate struct ItemSpanRow: Decodable, Sendable {
        let id: UUID
        let startsAt: String
        let endsAt: String
    }

    /// One item's span, parsed, while it is being moved.
    fileprivate struct ItemSpan: Sendable {
        let id: UUID
        let start: Date
        let end: Date
    }

    /// The identifier PostgREST echoes back from a narrow update.
    fileprivate struct ItemIdentifierRow: Decodable, Sendable {
        let id: UUID
    }

    /// New start/end for one item.
    fileprivate struct ItemSpanUpdate: Encodable, Sendable {
        let startsAt: String
        let endsAt: String
    }

    /// A `salon_opening_hours` row.
    fileprivate struct OpeningHoursRow: Decodable, Sendable {
        let weekday: Int
        let openMinutes: Int
        let closeMinutes: Int
    }

    /// The chair time one service consumes.
    fileprivate struct ServiceSpanRow: Decodable, Sendable {
        let id: UUID
        let durationMinutes: Int
        let preparationMinutes: Int
        let cleanupMinutes: Int

        /// Mirrors `SalonService.totalOccupancyMinutes`.
        var occupancyMinutes: Int {
            preparationMinutes + durationMinutes + cleanupMinutes
        }
    }

    /// An appointment reduced to the span and the chairs it occupies.
    fileprivate struct BusyRow: Decodable, Sendable {
        let startsAt: String?
        let endsAt: String?
        let appointmentItems: SupabaseEmbedded<BusyItemRow>?
    }

    /// The professional an occupied item belongs to.
    fileprivate struct BusyItemRow: Decodable, Sendable {
        let professionalID: UUID?
    }

    /// A `waitlist_entries` row.
    fileprivate struct WaitlistRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let clientID: UUID
        let serviceID: UUID
        let professionalID: UUID?
        let earliest: String
        let latest: String
        let notified: Bool
        let createdAt: String
    }

    /// A new waitlist entry.
    fileprivate struct WaitlistInsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let clientID: UUID
        let serviceID: UUID
        let professionalID: UUID?
        let earliest: String
        let latest: String
        let notified: Bool
    }

    /// The one column `updateStatus` writes; `updated_at` is a trigger's job.
    fileprivate struct AppointmentStatusUpdate: Encodable, Sendable {
        let status: String
    }

    /// `book_appointment(p_request jsonb)` — the argument name is the function's.
    fileprivate struct BookAppointmentParams: Encodable, Sendable {
        let pRequest: BookingRequest
    }

    /// The `cancel-appointment` request body.
    fileprivate struct CancelRequest: Encodable, Sendable {
        let appointmentID: UUID
        let reason: String?
    }

    /// The `cancel-appointment` reply. The `assessment` and `refund` members are
    /// deliberately not decoded: `AppointmentRepository.cancel` returns the
    /// appointment, and the fee breakdown reaches the UI through the order.
    fileprivate struct CancelResponse: Decodable, Sendable {
        let appointment: Appointment
    }
}
