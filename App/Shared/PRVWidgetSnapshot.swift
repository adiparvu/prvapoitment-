import Foundation
import PRVModels
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The single JSON document the app publishes into the shared app group for
/// the widget extension to read.
///
/// Widgets cannot reach the network or the app's repositories, so the app
/// writes a small, self-contained snapshot every time the relevant data
/// changes (sign-in, booking, cancellation, loyalty award, background
/// refresh) and the widget timelines read it back:
///
/// ```swift
/// // App target, after loading fresh data:
/// PRVWidgetSnapshot(appointment: next, loyalty: profile).write()
///
/// // Widget target, inside a TimelineProvider:
/// let snapshot = PRVWidgetSnapshot.load()
/// ```
///
/// Both targets share this file, so the encoding can never drift. Everything
/// is optional: a missing file, a signed-out user, or an empty calendar all
/// degrade to a graceful placeholder rather than an error.
public struct PRVWidgetSnapshot: Codable, Hashable, Sendable {
    /// Flattened, render-ready description of the client's next appointment.
    public struct NextAppointment: Codable, Hashable, Sendable {
        /// Raw appointment identifier, used to build the deep link.
        public var appointmentID: UUID
        /// Salon hosting the appointment.
        public var salonName: String
        /// Primary service ("Balayage & Gloss").
        public var serviceName: String
        /// Extra services beyond the primary one, for a "+2 more" affordance.
        public var additionalServiceCount: Int
        /// Professional performing the service, when one is assigned.
        public var professionalName: String?
        /// Appointment start.
        public var start: Date
        /// Appointment end.
        public var end: Date
        /// Human status ("Confirmed", "Pending").
        public var statusText: String

        /// Creates a next-appointment snapshot.
        public init(
            appointmentID: UUID,
            salonName: String,
            serviceName: String,
            additionalServiceCount: Int = 0,
            professionalName: String? = nil,
            start: Date,
            end: Date,
            statusText: String
        ) {
            self.appointmentID = appointmentID
            self.salonName = salonName
            self.serviceName = serviceName
            self.additionalServiceCount = additionalServiceCount
            self.professionalName = professionalName
            self.start = start
            self.end = end
            self.statusText = statusText
        }

        /// `prvbeauty://appointment/<uuid>` — where a widget tap lands.
        public var deepLinkURL: URL { PRVDeepLink.appointment(appointmentID) }

        /// Whether the visit is happening right now.
        public func isUnderway(at now: Date = .now) -> Bool {
            now >= start && now < resolvedEnd
        }

        /// Whether the visit has already finished and the widget should fall
        /// back to its empty treatment.
        public func hasFinished(at now: Date = .now) -> Bool {
            now >= resolvedEnd
        }

        /// Timer range for an auto-updating countdown: to the start before the
        /// visit, through the service once it is under way.
        public func countdownRange(at now: Date = .now) -> ClosedRange<Date> {
            if isUnderway(at: now) {
                return start...resolvedEnd
            }
            let upper = max(start, now.addingTimeInterval(1))
            return min(now, start)...upper
        }

        private var resolvedEnd: Date { max(end, start.addingTimeInterval(60)) }
    }

    /// Render-ready loyalty standing for the tier ring and card.
    public struct Loyalty: Codable, Hashable, Sendable {
        /// Current tier.
        public var tier: LoyaltyTier
        /// The tier being worked toward, or `nil` at the top of the ladder.
        public var nextTier: LoyaltyTier?
        /// Lifetime experience points.
        public var xp: Int
        /// Progress toward `nextTier`, 0…1 (1 at the top tier).
        public var progress: Double
        /// Points available to spend.
        public var spendablePoints: Int
        /// XP still needed to reach `nextTier`, or `nil` at the top tier.
        public var xpToNextTier: Int?

        /// Creates a loyalty snapshot.
        public init(
            tier: LoyaltyTier,
            nextTier: LoyaltyTier?,
            xp: Int,
            progress: Double,
            spendablePoints: Int,
            xpToNextTier: Int?
        ) {
            self.tier = tier
            self.nextTier = nextTier
            self.xp = xp
            self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
            self.spendablePoints = spendablePoints
            self.xpToNextTier = xpToNextTier
        }
    }

    /// The client's next appointment, or `nil` when nothing is booked.
    public var nextAppointment: NextAppointment?
    /// The client's loyalty standing, or `nil` for signed-out users.
    public var loyalty: Loyalty?
    /// When the app last wrote this snapshot.
    public var updatedAt: Date

    /// Creates a snapshot.
    public init(
        nextAppointment: NextAppointment? = nil,
        loyalty: Loyalty? = nil,
        updatedAt: Date = .now
    ) {
        self.nextAppointment = nextAppointment
        self.loyalty = loyalty
        self.updatedAt = updatedAt
    }

    // MARK: - Shared container

    /// App group shared by the app and the widget extension.
    public static let appGroupIdentifier = "group.com.prv.beauty"

    /// File name of the snapshot document inside the app group container.
    public static let filename = "prv-widget-snapshot.json"

    /// The shared app group container, or `nil` when the entitlement is
    /// missing (simulator previews, unsigned builds).
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Full URL of the snapshot document.
    public static var fileURL: URL? {
        containerURL?.appendingPathComponent(filename, isDirectory: false)
    }

    /// Reads the snapshot the app last published.
    /// - Returns: The decoded snapshot, or `nil` when the app has not written
    ///   one yet (first launch, signed out, entitlement unavailable).
    public static func load() -> PRVWidgetSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(PRVWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    /// Writes this snapshot into the shared container and asks WidgetKit to
    /// reload every timeline.
    ///
    /// The write is atomic and uses "until first user authentication" data
    /// protection so widgets can still render on a locked device after a
    /// reboot.
    /// - Returns: `true` when the snapshot reached disk.
    @discardableResult
    public func write() -> Bool {
        guard let url = Self.fileURL else { return false }
        do {
            let data = try Self.encoder.encode(self)
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            reloadWidgetTimelines()
            return true
        } catch {
            return false
        }
    }

    /// Removes the published snapshot (sign-out, account deletion) and
    /// reloads timelines so widgets fall back to their placeholder.
    public static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Building from domain models

extension PRVWidgetSnapshot {
    /// Projects domain models into the widget snapshot.
    ///
    /// Call this from the app target whenever the client's next appointment or
    /// loyalty standing changes, then `write()` the result.
    /// - Parameters:
    ///   - appointment: The next active appointment, or `nil`.
    ///   - loyalty: The client's loyalty profile, or `nil`.
    ///   - updatedAt: Timestamp recorded in the snapshot.
    public init(
        appointment: Appointment?,
        loyalty profile: LoyaltyProfile?,
        updatedAt: Date = .now
    ) {
        self.init(
            nextAppointment: appointment.flatMap(NextAppointment.init(appointment:)),
            loyalty: profile.map(Loyalty.init(profile:)),
            updatedAt: updatedAt
        )
    }
}

extension PRVWidgetSnapshot.NextAppointment {
    /// Flattens an ``Appointment`` into its widget projection.
    /// - Returns: `nil` when the appointment has no schedulable items.
    public init?(appointment: Appointment) {
        let ordered = appointment.items.sorted { $0.start < $1.start }
        guard let first = ordered.first,
              let start = appointment.start,
              let end = appointment.end
        else { return nil }

        self.init(
            appointmentID: appointment.id.rawValue,
            salonName: appointment.salonName,
            serviceName: first.serviceName,
            additionalServiceCount: max(0, ordered.count - 1),
            professionalName: first.professionalName,
            start: start,
            end: end,
            statusText: appointment.status.displayName
        )
    }
}

extension PRVWidgetSnapshot.Loyalty {
    /// Flattens a ``LoyaltyProfile`` into its widget projection.
    public init(profile: LoyaltyProfile) {
        let next = profile.tier.next
        self.init(
            tier: profile.tier,
            nextTier: next,
            xp: profile.xp,
            progress: profile.progressToNextTier,
            spendablePoints: profile.spendablePoints,
            xpToNextTier: next.map { max(0, $0.threshold - profile.xp) }
        )
    }
}

// MARK: - Fixtures

extension PRVWidgetSnapshot {
    /// Deterministic sample used by widget previews and by the redacted
    /// placeholder WidgetKit renders before real data arrives.
    public static var preview: PRVWidgetSnapshot {
        PRVWidgetSnapshot(
            nextAppointment: NextAppointment(
                appointmentID: PreviewData.upcomingAppointment.id.rawValue,
                salonName: PreviewData.salonLumiere.name,
                serviceName: PreviewData.serviceBalayage.name,
                additionalServiceCount: 1,
                professionalName: PreviewData.stylistAmelie.displayName,
                start: Date.now.addingTimeInterval(60 * 60 * 26),
                end: Date.now.addingTimeInterval(60 * 60 * 26 + 150 * 60),
                statusText: AppointmentStatus.confirmed.displayName
            ),
            loyalty: Loyalty(profile: PreviewData.loyaltyProfile)
        )
    }

    /// Sample with nothing booked — exercises the widgets' empty treatment.
    public static var previewEmpty: PRVWidgetSnapshot {
        PRVWidgetSnapshot(
            nextAppointment: nil,
            loyalty: Loyalty(profile: PreviewData.loyaltyProfile)
        )
    }
}
