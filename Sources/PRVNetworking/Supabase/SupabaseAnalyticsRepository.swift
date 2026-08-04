import Foundation
import PRVFoundation
import PRVModels

/// The live ``AnalyticsRepository``, backed by the `salon_dashboard` and
/// `organization_dashboard` Postgres functions defined in
/// `Backend/supabase/migrations/0005_analytics.sql`.
///
/// A ``DashboardSnapshot`` is seventeen figures drawn from `orders`,
/// `order_lines`, `refunds`, `appointments`, `appointment_items`, `shifts`,
/// `salon_opening_hours`, `professionals`, and `membership_subscriptions`, plus
/// three series. Assembling that on the device would mean a dozen round trips,
/// a dozen partial failures, and a dozen chances for two figures to disagree
/// because they were read a second apart. It is therefore one RPC: the whole
/// snapshot is computed inside a single transaction-consistent statement and
/// arrives as one JSON object shaped exactly like the model.
///
/// Both functions are `security definer` and authorize the caller themselves —
/// salon membership plus the `viewReports` permission — so a client who guesses
/// a salon id gets `PRV01`, which surfaces as ``APIError/forbidden``.
///
/// The window is half-open, `[periodStart, periodEnd)`, matching what
/// `PRVDashboardFeature` computes and what every comparison window assumes.
public struct SupabaseAnalyticsRepository: AnalyticsRepository, Sendable {
    private let client: SupabaseClient

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Dashboards

    /// The salon's dashboard for a period.
    ///
    /// - Parameters:
    ///   - salonID: The location to report on.
    ///   - periodStart: Inclusive start of the window.
    ///   - periodEnd: Exclusive end of the window.
    /// - Throws: ``APIError/forbidden`` when the caller is not staff at the
    ///   salon or lacks `viewReports`; ``APIError/notFound`` when the salon does
    ///   not exist or the window is not ordered.
    public func dashboard(
        salonID: Salon.ID,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> DashboardSnapshot {
        let row: DashboardRow = try await client.rpc(
            "salon_dashboard",
            params: SalonDashboardParams(
                pSalonID: salonID.rawValue,
                pStart: SupabaseTimestamp.string(from: periodStart),
                pEnd: SupabaseTimestamp.string(from: periodEnd)
            )
        )
        return try Self.makeSnapshot(row)
    }

    /// One dashboard per location of an organization, by name.
    ///
    /// The RPC returns a snapshot only for the locations the caller is staff at,
    /// so a regional manager sees their region and an owner sees the whole
    /// brand. An organization with no visible locations — including an id that
    /// belongs to no organization at all, which `SalonDashboardModel` can pass
    /// when a salon has no parent brand — yields an empty array rather than an
    /// error, so the comparison card simply does not appear.
    public func organizationDashboard(
        organizationID: Organization.ID,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> [DashboardSnapshot] {
        let rows: [DashboardRow] = try await client.rpc(
            "organization_dashboard",
            params: OrganizationDashboardParams(
                pOrganizationID: organizationID.rawValue,
                pStart: SupabaseTimestamp.string(from: periodStart),
                pEnd: SupabaseTimestamp.string(from: periodEnd)
            )
        )
        return try rows.map(Self.makeSnapshot)
    }

    // MARK: - Row mapping

    private static func makeSnapshot(_ row: DashboardRow) throws -> DashboardSnapshot {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        let series = try row.revenueSeries.map { point in
            MetricPoint(date: try SupabaseTimestamp.date(from: point.date), value: point.value)
        }
        return DashboardSnapshot(
            salonID: Salon.ID(row.salonID),
            periodStart: try SupabaseTimestamp.date(from: row.periodStart),
            periodEnd: try SupabaseTimestamp.date(from: row.periodEnd),
            revenue: Money(row.revenue, currency),
            revenueForecast: Money(row.revenueForecast, currency),
            appointmentCount: row.appointmentCount,
            completedCount: row.completedCount,
            cancellationRate: row.cancellationRate,
            occupancyRate: row.occupancyRate,
            newClientCount: row.newClientCount,
            returningClientCount: row.returningClientCount,
            retentionRate: row.retentionRate,
            averageTicket: Money(row.averageTicket, currency),
            productsSold: row.productsSold,
            membershipsSold: row.membershipsSold,
            revenueSeries: series,
            revenueByService: row.revenueByService.map { NamedMetric(name: $0.name, value: $0.value) },
            revenueByEmployee: row.revenueByEmployee.map { NamedMetric(name: $0.name, value: $0.value) }
        )
    }
}

// MARK: - Rows

extension SupabaseAnalyticsRepository {
    /// One `salon_dashboard` result.
    ///
    /// The function builds its JSON key by key to match ``DashboardSnapshot``,
    /// so every name here is one `PRVKeyCase` conversion away from the column
    /// the SQL emits. Instants arrive as whole-second UTC ISO-8601 strings and
    /// are parsed with ``SupabaseTimestamp`` rather than decoded as `Date`, for
    /// the same reason every other row type does it.
    fileprivate struct DashboardRow: Decodable, Sendable {
        let salonID: UUID
        let periodStart: String
        let periodEnd: String
        let currency: String
        let revenue: Decimal
        let revenueForecast: Decimal
        let appointmentCount: Int
        let completedCount: Int
        let cancellationRate: Double
        let occupancyRate: Double
        let newClientCount: Int
        let returningClientCount: Int
        let retentionRate: Double
        let averageTicket: Decimal
        let productsSold: Int
        let membershipsSold: Int
        let revenueSeries: [SeriesPointRow]
        let revenueByService: [NamedMetricRow]
        let revenueByEmployee: [NamedMetricRow]
    }

    /// One point of the daily revenue series.
    fileprivate struct SeriesPointRow: Decodable, Sendable {
        let date: String
        let value: Decimal
    }

    /// One labelled breakdown entry.
    fileprivate struct NamedMetricRow: Decodable, Sendable {
        let name: String
        let value: Decimal
    }
}

// MARK: - Parameters

extension SupabaseAnalyticsRepository {
    /// Arguments of `public.salon_dashboard(uuid, timestamptz, timestamptz)`.
    fileprivate struct SalonDashboardParams: Encodable, Sendable {
        let pSalonID: UUID
        let pStart: String
        let pEnd: String
    }

    /// Arguments of `public.organization_dashboard(uuid, timestamptz, timestamptz)`.
    fileprivate struct OrganizationDashboardParams: Encodable, Sendable {
        let pOrganizationID: UUID
        let pStart: String
        let pEnd: String
    }
}
