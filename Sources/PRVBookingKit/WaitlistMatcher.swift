import Foundation
import PRVModels

/// A window that has just opened up — a cancellation, a reschedule, or a shift
/// extension — offered back to the waitlist.
public struct FreedSlot: Hashable, Sendable {
    /// The salon the window belongs to.
    public var salonID: Salon.ID
    /// The freed window, including the professional it was assigned to, if any.
    public var slot: TimeSlot
    /// Services that can realistically be performed in this window — normally the
    /// services of the appointment that vacated it.
    public var serviceIDs: [SalonService.ID]

    /// Creates a freed slot.
    public init(salonID: Salon.ID, slot: TimeSlot, serviceIDs: [SalonService.ID]) {
        self.salonID = salonID
        self.slot = slot
        self.serviceIDs = serviceIDs
    }

    /// Derives the freed window from an appointment that is being cancelled.
    /// Returns `nil` when the appointment has no items and therefore no window.
    public init?(cancelling appointment: Appointment) {
        guard let start = appointment.start, let end = appointment.end else { return nil }
        self.salonID = appointment.salonID
        self.slot = TimeSlot(
            start: start,
            end: end,
            professionalID: appointment.items.first?.professionalID
        )
        self.serviceIDs = appointment.items.map(\.serviceID)
    }

    /// The freed window as an interval.
    public var interval: BookingInterval { BookingInterval(start: slot.start, end: slot.end) }
}

/// A waitlisted client paired with a window they can take.
public struct WaitlistMatch: Hashable, Sendable, Identifiable {
    /// The waiting client's entry.
    public var entry: WaitlistEntry
    /// The window being offered.
    public var slot: TimeSlot
    /// Zero-based position in the notification queue — offer rank 0 first.
    public var rank: Int

    /// Creates a match.
    public init(entry: WaitlistEntry, slot: TimeSlot, rank: Int) {
        self.entry = entry
        self.slot = slot
        self.rank = rank
    }

    /// Identity follows the waitlist entry.
    public var id: WaitlistEntry.ID { entry.id }
}

/// Matches a freed window against the waitlist and returns who to offer it to,
/// in the order they should be offered it.
///
/// Compatibility is decided by four rules, all of which must hold:
/// 1. **Same salon.** Entries for other locations never match.
/// 2. **Service compatibility.** The freed window must cover the service the client
///    is waiting for.
/// 3. **Professional compatibility.** A client waiting for a specific professional
///    only matches a window assigned to that professional (or an unassigned one). A
///    client with no preference matches anything.
/// 4. **Window containment.** By default the freed window must sit entirely inside
///    the client's stated availability — offering a slot the client cannot attend
///    burns the offer and delays everyone behind them. Relax with
///    ``Options/requiresFullWindowContainment`` when overlap is good enough.
///
/// Ordering is strict FIFO on `createdAt`, tie-broken by identifier so the queue is
/// reproducible. Waiting longer is the only privilege the waitlist grants.
public struct WaitlistMatcher: Sendable {
    /// Matching behaviour.
    public struct Options: Hashable, Sendable {
        /// Require the freed window to sit fully inside the client's availability.
        public var requiresFullWindowContainment: Bool
        /// Include entries that have already been notified about another window.
        public var includesNotifiedEntries: Bool
        /// Ceiling on returned matches — how many clients get pinged at once.
        public var maximumMatches: Int

        /// Creates an options set.
        public init(
            requiresFullWindowContainment: Bool = true,
            includesNotifiedEntries: Bool = false,
            maximumMatches: Int = 10
        ) {
            self.requiresFullWindowContainment = requiresFullWindowContainment
            self.includesNotifiedEntries = includesNotifiedEntries
            self.maximumMatches = max(0, maximumMatches)
        }
    }

    /// Matching behaviour.
    public let options: Options

    /// Creates a matcher.
    public init(options: Options = Options()) {
        self.options = options
    }

    /// The prioritised offer queue for a freed window.
    public func matches(for freed: FreedSlot, in entries: [WaitlistEntry]) -> [WaitlistMatch] {
        guard options.maximumMatches > 0 else { return [] }
        let eligible = entries.filter { isCompatible($0, with: freed) }
        let ordered = eligible.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt
                ? lhs.id.description < rhs.id.description
                : lhs.createdAt < rhs.createdAt
        }
        return ordered.prefix(options.maximumMatches).enumerated().map { index, entry in
            WaitlistMatch(entry: entry, slot: freed.slot, rank: index)
        }
    }

    /// The single client who should be offered the window first.
    public func bestMatch(for freed: FreedSlot, in entries: [WaitlistEntry]) -> WaitlistMatch? {
        matches(for: freed, in: entries).first
    }

    /// `true` when `entry` could take `freed`.
    public func isCompatible(_ entry: WaitlistEntry, with freed: FreedSlot) -> Bool {
        guard entry.salonID == freed.salonID else { return false }
        guard freed.serviceIDs.contains(entry.serviceID) else { return false }
        guard options.includesNotifiedEntries || !entry.notified else { return false }

        if let wanted = entry.professionalID,
           let assigned = freed.slot.professionalID,
           wanted != assigned {
            return false
        }

        let availability = BookingInterval(start: entry.earliest, end: entry.latest)
        let offered = freed.interval
        guard !offered.isEmpty, !availability.isEmpty else { return false }

        return options.requiresFullWindowContainment
            ? availability.contains(offered)
            : availability.overlaps(offered)
    }
}
