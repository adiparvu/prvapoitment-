import Foundation
import PRVFoundation
import PRVModels

/// The live ``MembershipRepository``, backed by the `membership_plans`,
/// `membership_benefits`, `membership_subscriptions`, `service_packages`, and
/// `package_services` tables.
///
/// Plans and packages are catalogue reads, and every one of them is a single
/// PostgREST round trip: benefits and included services come back as embedded
/// resources ordered by the `position` column the schema keeps for exactly that,
/// so a plan arrives complete rather than in pieces.
///
/// Buying is deliberately split in two. A package purchase produces an **order**
/// and stops there — what is actually charged is `order_totals`' business, and
/// taking the money is `create-payment-intent`'s — so this repository composes
/// the order through ``SupabasePaymentRepository/createOrder(_:)`` rather than
/// repeating the same insert sequence and the same RLS ordering a second time.
public struct SupabaseMembershipRepository: MembershipRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns.
    private static let listLimit = 100

    /// The plan projection: the row plus the benefits its value type absorbs.
    private static let planColumns = "*,membership_benefits(*)"
    /// A subscription carries its plan, aliased so the embed decodes as `plan`.
    private static let subscriptionColumns = "*,plan:membership_plans(*,membership_benefits(*))"
    /// The package projection: the row plus the services it bundles.
    private static let packageColumns = "*,package_services(service_id,quantity,position)"

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Catalogue

    /// Membership plans, for one salon or across the platform, oldest first.
    ///
    /// Inactive plans are not filtered out here: `MembershipPlan.isActive`
    /// carries that fact, and `membership_plans_select_public` already hides a
    /// salon's retired plans from everyone but its own staff — who need them in
    /// order to bring one back.
    public func plans(salonID: Salon.ID?) async throws -> [MembershipPlan] {
        var request = PostgRESTQuery("membership_plans")
            .selecting(Self.planColumns)
            .order("created_at")
            .limited(to: Self.listLimit)
        if let salonID {
            request = request.filter(.equals("salon_id", salonID.rawValue))
        }
        let rows: [MembershipPlanRow] = try await client.select(request)
        return rows.map(Self.makePlan)
    }

    /// Service packages, for one salon or across the platform, oldest first.
    public func packages(salonID: Salon.ID?) async throws -> [ServicePackage] {
        var request = PostgRESTQuery("service_packages")
            .selecting(Self.packageColumns)
            .order("created_at")
            .limited(to: Self.listLimit)
        if let salonID {
            request = request.filter(.equals("salon_id", salonID.rawValue))
        }
        let rows: [ServicePackageRow] = try await client.select(request)
        return rows.map(Self.makePackage)
    }

    // MARK: - Subscriptions

    /// The user's subscriptions, oldest first, each with its plan attached.
    public func subscriptions(userID: User.ID) async throws -> [MembershipSubscription] {
        let request = PostgRESTQuery("membership_subscriptions")
            .selecting(Self.subscriptionColumns)
            .filter(.equals("user_id", userID.rawValue))
            .order("created_at")
            .limited(to: Self.listLimit)
        let rows: [MembershipSubscriptionRow] = try await client.select(request)
        return try rows.map(Self.makeSubscription)
    }

    /// Subscribes the user to a plan.
    ///
    /// The plan is read first so an unknown identifier fails as
    /// ``APIError/notFound`` rather than as a foreign-key violation, and so the
    /// billing cycle that fixes the renewal date comes from the salon's own row
    /// rather than from anything the caller supplied. `started_at` is written
    /// alongside `renews_at` because a check constraint couples the two, and
    /// both must therefore be derived from a single instant.
    ///
    /// Recurring billing is not started here: `stripe_subscription_id` stays
    /// null until a server-side subscription is attached to the row.
    public func subscribe(planID: MembershipPlan.ID, userID: User.ID) async throws -> MembershipSubscription {
        let membershipPlan = try await plan(id: planID)
        let startedAt = Date.now
        let renewsAt = startedAt
            .addingTimeInterval(TimeInterval(membershipPlan.cycle.months) * 30 * 24 * 3_600)

        let payload = MembershipSubscriptionInsert(
            planID: planID.rawValue,
            userID: userID.rawValue,
            startedAt: SupabaseTimestamp.string(from: startedAt),
            renewsAt: SupabaseTimestamp.string(from: renewsAt)
        )
        let row: MembershipSubscriptionRow = try await client.insert(
            into: "membership_subscriptions",
            values: payload,
            returning: Self.subscriptionColumns
        )
        return try Self.makeSubscription(row)
    }

    /// Cancels a subscription and returns it with its plan attached.
    ///
    /// `cancelled_at` is written in the same statement as the status because a
    /// check constraint refuses a cancelled row without one. An identifier that
    /// matches nothing — or a subscription the caller does not own — updates no
    /// rows, which PostgREST reports as ``APIError/notFound``.
    public func cancelSubscription(id: MembershipSubscription.ID) async throws -> MembershipSubscription {
        let payload = MembershipSubscriptionCancellation(
            status: MembershipSubscription.Status.cancelled.rawValue,
            cancelledAt: SupabaseTimestamp.string(from: .now)
        )
        let row: MembershipSubscriptionRow = try await client.update(
            "membership_subscriptions",
            values: payload,
            filters: [.equals("id", id.rawValue)],
            returning: Self.subscriptionColumns
        )
        return try Self.makeSubscription(row)
    }

    // MARK: - Packages

    /// Turns a package into a payable order awaiting payment.
    ///
    /// The order is composed server-side by ``SupabasePaymentRepository`` — one
    /// `package` line priced at the package price and referencing the package it
    /// came from — and left at `awaiting_payment`. What is finally charged is
    /// decided by `create-payment-intent` from the lines, never from a figure
    /// this call passes along.
    public func purchasePackage(packageID: ServicePackage.ID, userID: User.ID) async throws -> Order {
        let bundle = try await servicePackage(id: packageID)
        let line = OrderLine(
            kind: .package,
            title: bundle.name,
            unitPrice: bundle.packagePrice,
            referenceID: packageID.rawValue
        )
        let order = Order(
            salonID: bundle.salonID,
            clientID: userID,
            lines: [line],
            status: .awaitingPayment,
            currency: bundle.packagePrice.currency
        )
        return try await SupabasePaymentRepository(client: client).createOrder(order)
    }

    // MARK: - Single-row reads

    /// One plan with its benefits.
    private func plan(id: MembershipPlan.ID) async throws -> MembershipPlan {
        let request = PostgRESTQuery("membership_plans")
            .selecting(Self.planColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: MembershipPlanRow = try await client.select(request)
        return Self.makePlan(row)
    }

    /// One package with the services it bundles.
    private func servicePackage(id: ServicePackage.ID) async throws -> ServicePackage {
        let request = PostgRESTQuery("service_packages")
            .selecting(Self.packageColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: ServicePackageRow = try await client.select(request)
        return Self.makePackage(row)
    }

    // MARK: - Row mapping

    private static func makePlan(_ row: MembershipPlanRow) -> MembershipPlan {
        let benefits = (row.membershipBenefits?.values ?? [])
            .sorted { $0.position < $1.position }
            .map { benefit in
                MembershipBenefit(
                    id: MembershipBenefit.ID(benefit.id),
                    kind: MembershipBenefit.Kind(rawValue: benefit.kind) ?? .partnerBenefit,
                    title: benefit.title,
                    value: benefit.value,
                    serviceID: benefit.serviceID.map { SalonService.ID($0) }
                )
            }
        return MembershipPlan(
            id: MembershipPlan.ID(row.id),
            salonID: Salon.ID(row.salonID),
            tier: MembershipTier(rawValue: row.tier) ?? .custom,
            name: row.name,
            details: row.details,
            price: Money(row.priceAmount, Currency(rawValue: row.priceCurrency.trimmed) ?? .eur),
            cycle: BillingCycle(rawValue: row.cycle) ?? .monthly,
            benefits: benefits,
            isActive: row.isActive
        )
    }

    private static func makeSubscription(_ row: MembershipSubscriptionRow) throws -> MembershipSubscription {
        MembershipSubscription(
            id: MembershipSubscription.ID(row.id),
            planID: MembershipPlan.ID(row.planID),
            plan: row.plan?.first.map(makePlan),
            userID: User.ID(row.userID),
            status: MembershipSubscription.Status(rawValue: row.status) ?? .active,
            startedAt: try SupabaseTimestamp.date(from: row.startedAt),
            renewsAt: try SupabaseTimestamp.date(from: row.renewsAt),
            cancelledAt: SupabaseTimestamp.optionalDate(from: row.cancelledAt)
        )
    }

    private static func makePackage(_ row: ServicePackageRow) -> ServicePackage {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        // `quantity` is how many sessions of a service the bundle includes, and
        // `ServicePackage.serviceIDs` is a sequence — so two sessions read as two
        // entries rather than silently collapsing into one.
        let serviceIDs = (row.packageServices?.values ?? [])
            .sorted { $0.position < $1.position }
            .flatMap { included in
                Array(repeating: SalonService.ID(included.serviceID), count: max(1, included.quantity))
            }
        return ServicePackage(
            id: ServicePackage.ID(row.id),
            salonID: Salon.ID(row.salonID),
            name: row.name,
            details: row.details,
            theme: ServicePackage.Theme(rawValue: row.theme) ?? .custom,
            serviceIDs: serviceIDs,
            regularPrice: Money(row.regularPrice, currency),
            packagePrice: Money(row.packagePrice, currency),
            imageURL: row.imageURL.flatMap(URL.init(string:)),
            validityDays: row.validityDays,
            isActive: row.isActive
        )
    }
}

// MARK: - Rows

extension SupabaseMembershipRepository {
    /// A `membership_plans` row plus its embedded benefits.
    fileprivate struct MembershipPlanRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let tier: String
        let name: String
        let details: String
        let priceAmount: Decimal
        let priceCurrency: String
        let cycle: String
        let isActive: Bool
        let membershipBenefits: SupabaseEmbedded<MembershipBenefitRow>?
    }

    /// A `membership_benefits` row.
    fileprivate struct MembershipBenefitRow: Decodable, Sendable {
        let id: UUID
        let kind: String
        let title: String
        let value: Int?
        let serviceID: UUID?
        let position: Int
    }

    /// A `membership_subscriptions` row, with its plan under the `plan:` alias.
    fileprivate struct MembershipSubscriptionRow: Decodable, Sendable {
        let id: UUID
        let planID: UUID
        let userID: UUID
        let status: String
        let startedAt: String
        let renewsAt: String
        let cancelledAt: String?
        let plan: SupabaseEmbedded<MembershipPlanRow>?
    }

    /// A `service_packages` row plus the services it bundles.
    fileprivate struct ServicePackageRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let name: String
        let details: String
        let theme: String
        let regularPrice: Decimal
        let packagePrice: Decimal
        let currency: String
        let imageURL: String?
        let validityDays: Int
        let isActive: Bool
        let packageServices: SupabaseEmbedded<PackageServiceRow>?
    }

    /// A `package_services` join row.
    fileprivate struct PackageServiceRow: Decodable, Sendable {
        let serviceID: UUID
        let quantity: Int
        let position: Int
    }
}

// MARK: - Payloads

extension SupabaseMembershipRepository {
    /// The columns a new subscription supplies; the rest are server-owned.
    fileprivate struct MembershipSubscriptionInsert: Encodable, Sendable {
        let planID: UUID
        let userID: UUID
        let startedAt: String
        let renewsAt: String
    }

    /// The cancellation write: status and timestamp together, because the check
    /// constraint refuses one without the other.
    fileprivate struct MembershipSubscriptionCancellation: Encodable, Sendable {
        let status: String
        let cancelledAt: String
    }
}
