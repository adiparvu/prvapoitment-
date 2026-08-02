import Foundation
import PRVModels

// The primitives every booking engine in this kit is built from. Everything here
// is pure value semantics with an explicitly injected `Calendar` — no `Date.now`,
// no locale sniffing, no global state — so the whole kit is byte-for-byte
// reproducible on device, in previews, and on CI.

// MARK: - Calendar

extension Calendar {
    /// The calendar the booking engines fall back to when the caller injects nothing.
    ///
    /// Deliberately pinned to the Gregorian calendar in UTC with the POSIX locale so
    /// scheduling arithmetic is reproducible across devices, regions, and test runs.
    /// Production call sites should inject a calendar carrying the *salon's* time zone
    /// (`var c = Calendar(identifier: .gregorian); c.timeZone = salonTimeZone`), because
    /// opening hours are expressed in the salon's wall clock.
    public static let prvBooking: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Resolves a wall-clock time on the day containing `dayStart`.
    ///
    /// Uses date components rather than second arithmetic so daylight-saving
    /// transitions never shift "09:00" into "10:00". Values of 1440 and above roll
    /// into the following day, which is how past-midnight closing times are modelled.
    func wallClockDate(onDayContaining dayStart: Date, minutesFromMidnight minutes: Int) -> Date? {
        guard minutes >= 0 else { return nil }
        var components = dateComponents([.year, .month, .day], from: dayStart)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return date(from: components)
    }

    /// Whole minutes between two instants, truncated toward zero.
    func minutes(from start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) / 60)
    }
}

// MARK: - BookingInterval

/// A half-open time interval `[start, end)`.
///
/// Half-open semantics are what make back-to-back bookings legal: an appointment
/// ending at 11:00 does not collide with one starting at 11:00.
public struct BookingInterval: Hashable, Sendable, Comparable {
    public var start: Date
    public var end: Date

    /// Creates an interval. `end` is clamped to `start` so the type can never
    /// represent negative duration.
    public init(start: Date, end: Date) {
        self.start = start
        self.end = Swift.max(start, end)
    }

    /// Creates an interval of `minutes` length beginning at `start`.
    public init(start: Date, minutes: Int) {
        self.init(start: start, end: start.addingTimeInterval(TimeInterval(Swift.max(0, minutes) * 60)))
    }

    /// Length in seconds.
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Length in whole minutes, rounded to nearest.
    public var durationMinutes: Int { Int((duration / 60).rounded()) }

    /// `true` when the interval carries no time at all.
    public var isEmpty: Bool { end <= start }

    /// Half-open overlap test — touching endpoints do **not** overlap.
    public func overlaps(_ other: BookingInterval) -> Bool {
        start < other.end && end > other.start
    }

    /// `true` when `other` lies entirely inside the receiver.
    public func contains(_ other: BookingInterval) -> Bool {
        other.start >= start && other.end <= end
    }

    /// `true` when `date` lies inside the half-open interval.
    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Grows the interval by `minutes` on both sides — how buffer time is applied.
    public func padded(byMinutes minutes: Int) -> BookingInterval {
        guard minutes != 0 else { return self }
        let delta = TimeInterval(minutes * 60)
        return BookingInterval(start: start.addingTimeInterval(-delta), end: end.addingTimeInterval(delta))
    }

    /// The shared portion of two intervals, or `nil` when they do not overlap.
    public func intersection(_ other: BookingInterval) -> BookingInterval? {
        let lower = Swift.max(start, other.start)
        let upper = Swift.min(end, other.end)
        guard lower < upper else { return nil }
        return BookingInterval(start: lower, end: upper)
    }

    public static func < (lhs: BookingInterval, rhs: BookingInterval) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }
}

// MARK: - ServiceOccupancy

/// The chair time a chain of services consumes, split into the part the client
/// sees and the internal padding around it.
///
/// For a chain `A → B` the reserved block is
/// `A.prep + A.duration + A.cleanup + B.prep + B.duration + B.cleanup`. The client
/// arrives once `A`'s preparation is done and leaves before `B`'s cleanup begins,
/// so the visible appointment window is the block minus the leading preparation and
/// the trailing cleanup. Interior prep/cleanup stays inside the client's window,
/// which is exactly how a salon experiences a multi-service visit.
public struct ServiceOccupancy: Hashable, Sendable {
    /// Preparation performed before the client's first service starts.
    public let leadPreparationMinutes: Int
    /// The window the client actually occupies, add-ons included.
    public let clientFacingMinutes: Int
    /// Cleanup performed after the client's last service ends.
    public let trailingCleanupMinutes: Int
    /// Spacing the salon wants either side of the block — the largest requested by
    /// any service in the chain.
    public let bufferMinutes: Int

    /// Computes the occupancy of `services` performed back to back.
    /// - Parameters:
    ///   - services: the chain, in the order it will be performed.
    ///   - additionalMinutes: extra client-facing minutes, e.g. selected add-ons.
    public init(services: [SalonService], additionalMinutes: Int = 0) {
        let extra = Swift.max(0, additionalMinutes)
        guard let first = services.first, let last = services.last else {
            self.leadPreparationMinutes = 0
            self.clientFacingMinutes = extra
            self.trailingCleanupMinutes = 0
            self.bufferMinutes = 0
            return
        }
        let block = services.reduce(0) { $0 + Swift.max(0, $1.totalOccupancyMinutes) }
        let lead = Swift.max(0, first.preparationMinutes)
        let trail = Swift.max(0, last.cleanupMinutes)
        self.leadPreparationMinutes = lead
        self.trailingCleanupMinutes = trail
        self.clientFacingMinutes = Swift.max(0, block - lead - trail) + extra
        self.bufferMinutes = services.map { Swift.max(0, $0.bufferMinutes) }.max() ?? 0
    }

    /// Explicit initializer, mainly for tests and bespoke resource maths.
    public init(
        leadPreparationMinutes: Int,
        clientFacingMinutes: Int,
        trailingCleanupMinutes: Int,
        bufferMinutes: Int
    ) {
        self.leadPreparationMinutes = Swift.max(0, leadPreparationMinutes)
        self.clientFacingMinutes = Swift.max(0, clientFacingMinutes)
        self.trailingCleanupMinutes = Swift.max(0, trailingCleanupMinutes)
        self.bufferMinutes = Swift.max(0, bufferMinutes)
    }

    /// Total minutes the chair/room is unavailable, excluding buffer.
    public var totalMinutes: Int {
        leadPreparationMinutes + clientFacingMinutes + trailingCleanupMinutes
    }

    /// The full block to reserve when the client's visit begins at `start`.
    public func occupancyBlock(forClientStart start: Date) -> BookingInterval {
        let blockStart = start.addingTimeInterval(TimeInterval(-leadPreparationMinutes * 60))
        return BookingInterval(start: blockStart, minutes: totalMinutes)
    }

    /// The client-visible window for a block that begins at `start`.
    public func clientWindow(forBlockStart start: Date) -> BookingInterval {
        let clientStart = start.addingTimeInterval(TimeInterval(leadPreparationMinutes * 60))
        return BookingInterval(start: clientStart, minutes: clientFacingMinutes)
    }
}

// MARK: - Opening hours

extension Array where Element == OpeningHours {
    /// The bookable windows on the day containing `day`, resolved to wall-clock instants.
    ///
    /// A weekday with no matching `OpeningHours` entry is treated as closed, as is an
    /// entry with no intervals. Intervals are returned sorted and never inverted.
    public func bookingWindows(on day: Date, calendar: Calendar) -> [BookingInterval] {
        let weekday = calendar.component(.weekday, from: day)
        guard let hours = first(where: { $0.weekday == weekday }), !hours.isClosed else { return [] }
        let dayStart = calendar.startOfDay(for: day)
        return hours.intervals
            .compactMap { interval -> BookingInterval? in
                guard interval.closeMinutes > interval.openMinutes else { return nil }
                guard
                    let open = calendar.wallClockDate(onDayContaining: dayStart, minutesFromMidnight: interval.openMinutes),
                    let close = calendar.wallClockDate(onDayContaining: dayStart, minutesFromMidnight: interval.closeMinutes)
                else { return nil }
                return BookingInterval(start: open, end: close)
            }
            .sorted()
    }

    /// `true` when the salon is open for the whole of `interval`.
    public func isOpen(during interval: BookingInterval, calendar: Calendar) -> Bool {
        window(containing: interval, calendar: calendar) != nil
    }

    /// The opening window that fully contains `interval`, if any.
    public func window(containing interval: BookingInterval, calendar: Calendar) -> BookingInterval? {
        bookingWindows(on: interval.start, calendar: calendar).first { $0.contains(interval) }
    }
}

// MARK: - BusyIndex

/// Committed chair time, indexed by professional.
///
/// Only appointments whose status `isActive` occupy time — cancelled, completed and
/// no-show appointments free their slots back up. Items with no professional are
/// treated as salon-wide load: they block the anonymous resource used by salons with
/// no staff records, but they do not block a *named* professional, because nobody has
/// been committed to them yet.
struct BusyIndex: Sendable {
    private let perProfessional: [Professional.ID: [BookingInterval]]
    private let unassignedIntervals: [BookingInterval]
    private let allIntervals: [BookingInterval]

    init(appointments: [Appointment], includesInactive: Bool = false) {
        var perProfessional: [Professional.ID: [BookingInterval]] = [:]
        var unassigned: [BookingInterval] = []
        var all: [BookingInterval] = []

        for appointment in appointments where includesInactive || appointment.status.isActive {
            for item in appointment.items {
                let interval = BookingInterval(start: item.start, end: item.end)
                guard !interval.isEmpty else { continue }
                all.append(interval)
                if let professionalID = item.professionalID {
                    perProfessional[professionalID, default: []].append(interval)
                } else {
                    unassigned.append(interval)
                }
            }
        }

        self.perProfessional = perProfessional.mapValues { $0.sorted() }
        self.unassignedIntervals = unassigned.sorted()
        self.allIntervals = all.sorted()
    }

    /// Committed intervals for a professional; `nil` returns salon-wide load.
    func intervals(for professionalID: Professional.ID?) -> [BookingInterval] {
        guard let professionalID else { return allIntervals }
        return perProfessional[professionalID] ?? []
    }

    /// Intervals belonging to no professional yet.
    var unassigned: [BookingInterval] { unassignedIntervals }

    /// Minutes already booked inside `window` — the load-balancing metric.
    func bookedMinutes(for professionalID: Professional.ID?, within window: BookingInterval) -> Int {
        intervals(for: professionalID).reduce(0) { total, interval in
            guard let overlap = interval.intersection(window) else { return total }
            return total + overlap.durationMinutes
        }
    }

    /// The latest committed end at or before `date`, for the given professional.
    func lastEnd(before date: Date, for professionalID: Professional.ID?) -> Date? {
        intervals(for: professionalID).filter { $0.end <= date }.map(\.end).max()
    }

    /// The earliest committed start at or after `date`, for the given professional.
    func nextStart(after date: Date, for professionalID: Professional.ID?) -> Date? {
        intervals(for: professionalID).filter { $0.start >= date }.map(\.start).min()
    }
}
