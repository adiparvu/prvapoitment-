import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// Why adding an appointment to the system calendar failed.
enum BookingCalendarError: Error, Sendable {
    case accessDenied
    case noWritableCalendar
    case unavailable

    /// Human, non-technical explanation for a toast.
    var message: String {
        switch self {
        case .accessDenied:
            "Calendar access is off. Turn it on in Settings to save your appointments."
        case .noWritableCalendar:
            "No writable calendar was found on this device."
        case .unavailable:
            "Calendars aren't available on this device."
        }
    }
}

/// Writes appointments to the user's calendar.
///
/// Every EventKit object is created and consumed inside a single `nonisolated`
/// async function, so the non-`Sendable` store never crosses an isolation
/// boundary — the call site simply passes value types in.
///
/// - Note: The app target must declare `NSCalendarsWriteOnlyAccessUsageDescription`
///   in its Info.plist for the permission prompt to appear.
enum BookingCalendar {
    /// Saves an appointment to the user's default calendar with a one-hour
    /// reminder.
    /// - Throws: ``BookingCalendarError`` when access is refused or no
    ///   writable calendar exists.
    static func add(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String?
    ) async throws {
        #if canImport(EventKit)
        let store = EKEventStore()
        let granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        guard granted else { throw BookingCalendarError.accessDenied }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw BookingCalendarError.noWritableCalendar
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(60))
        event.location = location
        event.notes = notes
        event.calendar = calendar
        event.addAlarm(EKAlarm(relativeOffset: -3_600))

        try store.save(event, span: .thisEvent, commit: true)
        #else
        throw BookingCalendarError.unavailable
        #endif
    }
}
