import Foundation
import PRVFoundation
import PRVModels

/// Device-local storage for "recently viewed" salons.
///
/// `0001_schema.sql` has no `recently_viewed` table and `0002_rls.sql` grants no
/// policy for one, so the list is kept on the device in `UserDefaults` rather
/// than invented server-side. It is browsing history, not shared state: it needs
/// no cross-device consistency, and keeping it local means an anonymous browser
/// gets the feature too. Promote it to a table (plus an RLS policy scoped to
/// `user_id = auth.uid()`) if the product ever wants it synced.
///
/// The actor exists purely to keep the `UserDefaults` access off the repository's
/// `Sendable` surface.
public actor RecentlyViewedSalonStore {
    private static let storageKey = "com.prv.beauty.recentlyViewedSalons"
    private static let capacity = 10
    private let defaults: UserDefaults

    /// Creates a store over the standard defaults suite.
    public init() {
        defaults = .standard
    }

    /// Records `id` as the most recently viewed salon.
    public func record(_ id: UUID) {
        var identifiers = defaults.stringArray(forKey: Self.storageKey) ?? []
        let value = id.uuidString
        identifiers.removeAll { $0 == value }
        identifiers.insert(value, at: 0)
        defaults.set(Array(identifiers.prefix(Self.capacity)), forKey: Self.storageKey)
    }

    /// The recorded salon ids, most recent first.
    public func identifiers() -> [UUID] {
        (defaults.stringArray(forKey: Self.storageKey) ?? []).compactMap(UUID.init(uuidString:))
    }
}

/// The live ``SalonRepository``, backed by the `salons`, `salon_opening_hours`,
/// `prepayment_policies`, `services`, `service_add_ons`, `professionals`,
/// `certificates`, `portfolio_items`, `reviews`, and `review_likes` tables.
///
/// Every read is a single PostgREST round trip: the child tables come back as
/// embedded resources rather than as follow-up queries, so a salon profile is one
/// request rather than five. Row Level Security (`0002_rls.sql`) already scopes
/// what each caller may see, so no method re-implements authorization.
public struct SupabaseSalonRepository: SalonRepository {
    private let client: SupabaseClient
    private let recentlyViewed: RecentlyViewedSalonStore

    /// Widest set of rows any list endpoint returns, so one careless filter can
    /// never page the entire table into memory.
    private static let listLimit = 100

    /// The salon projection: the row plus the two tables its value type absorbs.
    private static let salonColumns = "*,salon_opening_hours(*),prepayment_policies(*)"
    private static let serviceColumns = "*,service_add_ons(*)"
    private static let professionalColumns =
        "*,certificates(*),portfolio_items(*),professional_services(service_id)"
    private static let reviewColumns = "*,review_likes(user_id)"

    /// Creates the repository.
    ///
    /// - Parameters:
    ///   - client: The shared Supabase transport.
    ///   - recentlyViewed: Where browsing history is kept.
    public init(
        client: SupabaseClient,
        recentlyViewed: RecentlyViewedSalonStore = RecentlyViewedSalonStore()
    ) {
        self.client = client
        self.recentlyViewed = recentlyViewed
    }

    // MARK: - Discovery

    /// Translates a ``SalonSearchQuery`` into PostgREST filters.
    ///
    /// Text search is an `ilike` over `name` and `about`; categories and languages
    /// use array overlap (`ov`, "any of"); amenities use array containment (`cs`,
    /// "all of") — matching `InMemoryBackend`'s `isDisjoint` / `isSuperset`
    /// semantics exactly.
    ///
    /// Two parts of the query cannot be expressed as a filter and are finished on
    /// the device:
    /// - **distance**: the schema stores plain `latitude`/`longitude` columns with
    ///   no PostGIS extension, so `near` becomes a bounding-box filter (the exact
    ///   use the `salons_geo_idx` index was created for) and the precise haversine
    ///   distance then trims and orders the page.
    /// - **availability**: opening hours are weekday/minute rows with no date
    ///   dimension, so "open now" is evaluated against the embedded hours.
    ///
    /// `maxPrice` is not applied: price lives on `services`, and filtering salons
    /// by it needs an aggregate the schema does not expose. `InMemoryBackend`
    /// ignores it too.
    public func searchSalons(_ query: SalonSearchQuery) async throws -> [Salon] {
        var request = PostgRESTQuery("salons")
            .selecting(Self.salonColumns)
            .filter(.isTrue("is_active"))
            .limited(to: Self.listLimit)

        let needle = query.text.trimmed
        if !needle.isEmpty {
            request = request.filter(.any(of: [
                .caseInsensitiveContains("name", needle),
                .caseInsensitiveContains("about", needle),
            ]))
        }
        if !query.categories.isEmpty {
            request = request.filter(.overlaps("categories", query.categories.map(\.rawValue)))
        }
        if !query.amenities.isEmpty {
            request = request.filter(.containsAll("amenities", query.amenities.map(\.rawValue)))
        }
        if !query.languages.isEmpty {
            request = request.filter(.overlaps("languages", query.languages))
        }
        if let minRating = query.minRating {
            request = request.filter(.atLeast("rating", String(minRating)))
        }
        if query.verifiedOnly {
            request = request.filter(.isTrue("is_verified"))
        }
        if let near = query.near {
            request = request.filter(Self.boundingBox(around: near, kilometres: query.maxDistanceKm))
        }

        switch query.sort {
        case .rating:
            request = request.order("rating", ascending: false)
        case .recommended:
            request = request
                .order("is_verified", ascending: false)
                .order("rating", ascending: false)
                .order("review_count", ascending: false)
        case .distance, .priceLowToHigh, .priceHighToLow:
            break
        }

        var salons = try await fetchSalons(request)
        salons = Self.filterByAvailability(salons, window: query.availability)
        if let near = query.near {
            salons = Self.applyDistance(to: salons, from: near, maxKilometres: query.maxDistanceKm)
            if query.sort == .distance {
                salons.sort {
                    Self.distanceKilometres(from: near, to: $0.address.coordinate)
                        < Self.distanceKilometres(from: near, to: $1.address.coordinate)
                }
            }
        }
        return salons
    }

    /// One salon, with its opening hours and prepayment policy.
    public func salon(id: Salon.ID) async throws -> Salon {
        let request = PostgRESTQuery("salons")
            .selecting(Self.salonColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: SalonRow = try await client.select(request)
        return try Self.makeSalon(row)
    }

    /// The most-reviewed salons, which is what "trending" means to the product.
    public func trendingSalons() async throws -> [Salon] {
        let request = PostgRESTQuery("salons")
            .selecting(Self.salonColumns)
            .filter(.isTrue("is_active"))
            .order("review_count", ascending: false)
            .order("rating", ascending: false)
            .limited(to: 25)
        return try await fetchSalons(request)
    }

    /// Salons near `coordinate`, closest first.
    ///
    /// Without a coordinate — location permission denied, or the user has not been
    /// asked yet — this degrades to the highest-rated salons rather than failing.
    public func nearbySalons(_ coordinate: GeoCoordinate?) async throws -> [Salon] {
        var request = PostgRESTQuery("salons")
            .selecting(Self.salonColumns)
            .filter(.isTrue("is_active"))
            .limited(to: 50)
        guard let coordinate else {
            return try await fetchSalons(request.order("rating", ascending: false))
        }
        request = request.filter(Self.boundingBox(around: coordinate, kilometres: nil))
        let salons = try await fetchSalons(request)
        return salons.sorted {
            Self.distanceKilometres(from: coordinate, to: $0.address.coordinate)
                < Self.distanceKilometres(from: coordinate, to: $1.address.coordinate)
        }
    }

    /// The salons this device has opened, most recent first.
    public func recentlyViewedSalons() async throws -> [Salon] {
        let identifiers = await recentlyViewed.identifiers()
        guard !identifiers.isEmpty else { return [] }
        let request = PostgRESTQuery("salons")
            .selecting(Self.salonColumns)
            .filter(.within("id", identifiers))
            .limited(to: identifiers.count)
        let salons = try await fetchSalons(request)
        // Preserve recency order, which the server has no way to know about.
        return identifiers.compactMap { identifier in
            salons.first { $0.id.rawValue == identifier }
        }
    }

    /// Records a salon view. Local-only; see ``RecentlyViewedSalonStore``.
    public func markViewed(salonID: Salon.ID) async {
        await recentlyViewed.record(salonID.rawValue)
    }

    // MARK: - Catalogue

    /// Every service a salon offers, with its add-ons.
    ///
    /// Inactive services are not filtered out here: RLS already hides them from
    /// clients (`services_select_public`) while keeping them visible to staff,
    /// who need them to re-activate a service.
    public func services(salonID: Salon.ID) async throws -> [SalonService] {
        let request = PostgRESTQuery("services")
            .selecting(Self.serviceColumns)
            .filter(.equals("salon_id", salonID.rawValue))
            .order("name")
            .limited(to: Self.listLimit)
        let rows: [ServiceRow] = try await client.select(request)
        return try rows.map(Self.makeService)
    }

    /// One service, with its add-ons.
    public func service(id: SalonService.ID) async throws -> SalonService {
        let request = PostgRESTQuery("services")
            .selecting(Self.serviceColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: ServiceRow = try await client.select(request)
        return try Self.makeService(row)
    }

    /// The salon's professionals, with certificates, portfolio, and service list.
    public func professionals(salonID: Salon.ID) async throws -> [Professional] {
        let request = PostgRESTQuery("professionals")
            .selecting(Self.professionalColumns)
            .filter(.equals("salon_id", salonID.rawValue))
            .order("display_name")
            .limited(to: Self.listLimit)
        let rows: [ProfessionalRow] = try await client.select(request)
        return try rows.map(Self.makeProfessional)
    }

    /// One professional — salon staff or independent freelancer.
    public func professional(id: Professional.ID) async throws -> Professional {
        let request = PostgRESTQuery("professionals")
            .selecting(Self.professionalColumns)
            .filter(.equals("id", id.rawValue))
            .single()
        let row: ProfessionalRow = try await client.select(request)
        return try Self.makeProfessional(row)
    }

    // MARK: - Reviews

    /// A salon's reviews, newest first.
    ///
    /// `review_likes` is embedded rather than counted: its RLS policy only exposes
    /// the caller's own rows, so an empty embed means "I have not liked this" and
    /// the aggregate stays in `reviews.like_count`, where a trigger maintains it.
    public func reviews(salonID: Salon.ID) async throws -> [Review] {
        let request = PostgRESTQuery("reviews")
            .selecting(Self.reviewColumns)
            .filter(.equals("salon_id", salonID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [ReviewRow] = try await client.select(request)
        return try rows.map(Self.makeReview)
    }

    /// Publishes a review.
    ///
    /// Moderation state, like count, and the salon's rating aggregate are all
    /// server-owned (`0003_functions_triggers.sql`), so the stored representation
    /// is returned rather than the value that was submitted — a review normally
    /// comes back `.pending`.
    public func submitReview(_ review: Review) async throws -> Review {
        let payload = ReviewInsert(
            id: review.id.rawValue,
            salonID: review.salonID.rawValue,
            professionalID: review.professionalID?.rawValue,
            authorID: review.authorID.rawValue,
            authorName: review.authorName,
            authorAvatarURL: review.authorAvatarURL?.absoluteString,
            rating: review.rating,
            text: review.text,
            photoURLs: review.photoURLs.map(\.absoluteString),
            videoURLs: review.videoURLs.map(\.absoluteString),
            verifiedAppointmentID: review.verifiedAppointmentID?.rawValue
        )
        let row: ReviewRow = try await client.insert(
            into: "reviews",
            values: payload,
            returning: Self.reviewColumns
        )
        return try Self.makeReview(row)
    }

    /// Adds or removes the caller's like, returning the review as it now stands.
    ///
    /// The like itself is a row in `review_likes`; `reviews.like_count` is
    /// recomputed by trigger in the same transaction, so re-reading the review is
    /// what makes the returned count authoritative rather than guessed.
    public func toggleReviewLike(id: Review.ID) async throws -> Review {
        guard let userID = await client.currentUserID else { throw APIError.unauthorized }

        let existing: [ReviewLikeRow] = try await client.select(
            PostgRESTQuery("review_likes")
                .selecting("user_id")
                .filter(.equals("review_id", id.rawValue))
                .filter(.equals("user_id", userID))
        )

        if existing.isEmpty {
            _ = try await client.insert(
                into: "review_likes",
                values: ReviewLikeInsert(reviewID: id.rawValue, userID: userID),
                returning: "user_id",
                as: ReviewLikeRow.self
            )
        } else {
            try await client.deleteRows(
                from: "review_likes",
                filters: [.equals("review_id", id.rawValue), .equals("user_id", userID)]
            )
        }

        let row: ReviewRow = try await client.select(
            PostgRESTQuery("reviews")
                .selecting(Self.reviewColumns)
                .filter(.equals("id", id.rawValue))
                .single()
        )
        return try Self.makeReview(row)
    }

    // MARK: - Fetch helpers

    private func fetchSalons(_ request: PostgRESTQuery) async throws -> [Salon] {
        let rows: [SalonRow] = try await client.select(request)
        return try rows.map(Self.makeSalon)
    }

    // MARK: - Geography

    /// A latitude/longitude box around `centre`, used to let Postgres discard the
    /// bulk of the table on an index before the exact distance is computed.
    ///
    /// One degree of latitude is ~111.2 km everywhere; one degree of longitude
    /// shrinks with the cosine of the latitude, and is clamped near the poles so
    /// the box never collapses to nothing.
    private static func boundingBox(
        around centre: GeoCoordinate,
        kilometres: Double?
    ) -> [PostgRESTFilter] {
        let radius = min(max(kilometres ?? 25, 1), 500)
        let latitudeDelta = radius / 111.2
        let cosine = max(abs(cos(centre.latitude * .pi / 180)), 0.01)
        let longitudeDelta = radius / (111.32 * cosine)
        return [
            .atLeast("latitude", String(max(centre.latitude - latitudeDelta, -90))),
            .atMost("latitude", String(min(centre.latitude + latitudeDelta, 90))),
            .atLeast("longitude", String(max(centre.longitude - longitudeDelta, -180))),
            .atMost("longitude", String(min(centre.longitude + longitudeDelta, 180))),
        ]
    }

    /// Trims the bounding-box page down to the true radius.
    private static func applyDistance(
        to salons: [Salon],
        from centre: GeoCoordinate,
        maxKilometres: Double?
    ) -> [Salon] {
        guard let maxKilometres else { return salons }
        return salons.filter {
            distanceKilometres(from: centre, to: $0.address.coordinate) <= maxKilometres
        }
    }

    /// Great-circle distance in kilometres.
    ///
    /// Implemented here rather than with `CLLocation` so the networking layer
    /// stays free of CoreLocation (and of its main-thread-affine types).
    private static func distanceKilometres(from origin: GeoCoordinate, to target: GeoCoordinate) -> Double {
        let earthRadius = 6_371.0088
        let phi1 = origin.latitude * .pi / 180
        let phi2 = target.latitude * .pi / 180
        let deltaPhi = (target.latitude - origin.latitude) * .pi / 180
        let deltaLambda = (target.longitude - origin.longitude) * .pi / 180
        let haversine = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }

    // MARK: - Availability window

    /// Applies the "open now / today / this evening" chip.
    ///
    /// `salon_opening_hours` stores a weekday and minutes from midnight with no
    /// time zone, so the comparison uses the device's calendar — the same
    /// assumption `PRVBookingKit.AvailabilityEngine` makes when it lays slots out
    /// on a day.
    private static func filterByAvailability(
        _ salons: [Salon],
        window: SalonSearchQuery.AvailabilityWindow,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Salon] {
        guard window != .anyTime else { return salons }
        let weekday = calendar.component(.weekday, from: now)
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        return salons.filter { salon in
            let intervals = salon.openingHours
                .first { $0.weekday == weekday }
                .map(\.intervals) ?? []
            switch window {
            case .anyTime:
                return true
            case .today:
                return !intervals.isEmpty
            case .openNow:
                return intervals.contains { $0.openMinutes <= minutes && minutes < $0.closeMinutes }
            case .thisEvening:
                return intervals.contains { $0.closeMinutes > 18 * 60 && $0.closeMinutes > minutes }
            }
        }
    }

    // MARK: - Row mapping

    private static func makeSalon(_ row: SalonRow) throws -> Salon {
        let hoursByWeekday = Dictionary(grouping: row.salonOpeningHours?.values ?? []) { $0.weekday }
        let openingHours = hoursByWeekday
            .map { weekday, rows in
                OpeningHours(
                    weekday: weekday,
                    intervals: rows
                        .sorted { $0.openMinutes < $1.openMinutes }
                        .map { OpeningHours.Interval(openMinutes: $0.openMinutes, closeMinutes: $0.closeMinutes) }
                )
            }
            .sorted { $0.weekday < $1.weekday }

        let prepayment = row.prepaymentPolicies?.first.map { policy in
            PrepaymentPolicy(
                offeredPercents: policy.offeredPercents.compactMap(PrepaymentPolicy.Percent.init(rawValue:)),
                fullPrepaymentDiscountPercent: policy.fullPrepaymentDiscountPercent,
                rewardPointsMultiplier: policy.rewardPointsMultiplier,
                cashbackPercent: policy.cashbackPercent,
                grantsPriorityBooking: policy.grantsPriorityBooking
            )
        } ?? PrepaymentPolicy()

        return Salon(
            id: Salon.ID(row.id),
            name: row.name,
            tagline: row.tagline,
            about: row.about,
            categories: row.categories.compactMap(BusinessCategory.init(rawValue:)),
            address: Address(
                street: row.street,
                city: row.city,
                postalCode: row.postalCode,
                country: row.country.trimmed,
                coordinate: GeoCoordinate(latitude: row.latitude, longitude: row.longitude)
            ),
            phone: row.phone,
            email: row.email,
            heroImageURL: row.heroImageURL.flatMap(URL.init(string:)),
            heroVideoURL: row.heroVideoURL.flatMap(URL.init(string:)),
            galleryURLs: row.galleryURLs.compactMap(URL.init(string:)),
            instagramHandle: row.instagramHandle,
            tikTokHandle: row.tiktokHandle,
            virtualTourURL: row.virtualTourURL.flatMap(URL.init(string:)),
            amenities: row.amenities.compactMap(SalonAmenity.init(rawValue:)),
            languages: row.languages,
            openingHours: openingHours,
            policies: SalonPolicies(
                freeCancellationHours: row.policyFreeCancellationHours,
                lateCancellationFeePercent: row.policyLateCancellationPercent,
                noShowFeePercent: row.policyNoShowPercent,
                lateGraceMinutes: row.policyLateGraceMinutes,
                childrenAllowed: row.policyChildrenAllowed,
                notes: row.policyNotes
            ),
            prepaymentPolicy: prepayment,
            rating: row.rating,
            reviewCount: row.reviewCount,
            isVerified: row.isVerified,
            currency: Currency(rawValue: row.currency.trimmed) ?? .eur,
            organizationID: row.organizationID.map { PRVID<Organization>($0) },
            certificates: row.certificates,
            awards: row.awards,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }

    private static func makeService(_ row: ServiceRow) throws -> SalonService {
        let currency = Currency(rawValue: row.priceCurrency.trimmed) ?? .eur
        let addOns = (row.serviceAddOns?.values ?? [])
            .filter { $0.isActive }
            .map { addOn in
                ServiceAddOn(
                    id: ServiceAddOn.ID(addOn.id),
                    name: addOn.name,
                    price: Money(addOn.priceAmount, Currency(rawValue: addOn.priceCurrency.trimmed) ?? currency),
                    extraMinutes: addOn.extraMinutes
                )
            }
        return SalonService(
            id: SalonService.ID(row.id),
            salonID: row.salonID.map { Salon.ID($0) },
            name: row.name,
            details: row.details,
            category: BusinessCategory(rawValue: row.category) ?? .hairSalon,
            price: Money(row.priceAmount, currency),
            isStartingPrice: row.isStartingPrice,
            durationMinutes: row.durationMinutes,
            preparationMinutes: row.preparationMinutes,
            cleanupMinutes: row.cleanupMinutes,
            bufferMinutes: row.bufferMinutes,
            imageURL: row.imageURL.flatMap(URL.init(string:)),
            isActive: row.isActive,
            requiresPrepayment: row.requiresPrepayment,
            addOns: addOns
        )
    }

    private static func makeProfessional(_ row: ProfessionalRow) throws -> Professional {
        let certificates = try (row.certificates?.values ?? []).map { certificate in
            Certificate(
                id: Certificate.ID(certificate.id),
                title: certificate.title,
                issuer: certificate.issuer,
                issuedAt: try SupabaseTimestamp.date(from: certificate.issuedAt),
                documentURL: certificate.documentURL.flatMap(URL.init(string:))
            )
        }
        let portfolio = try (row.portfolioItems?.values ?? []).compactMap { item -> PortfolioItem? in
            guard let mediaURL = URL(string: item.mediaURL) else { return nil }
            return PortfolioItem(
                id: PortfolioItem.ID(item.id),
                kind: PortfolioItem.Kind(rawValue: item.kind) ?? .photo,
                mediaURL: mediaURL,
                beforeURL: item.beforeURL.flatMap(URL.init(string:)),
                caption: item.caption,
                createdAt: try SupabaseTimestamp.date(from: item.createdAt)
            )
        }
        return Professional(
            id: Professional.ID(row.id),
            userID: row.userID.map { User.ID($0) },
            salonID: row.salonID.map { Salon.ID($0) },
            displayName: row.displayName,
            title: row.title,
            biography: row.biography,
            photoURL: row.photoURL.flatMap(URL.init(string:)),
            yearsOfExperience: row.yearsOfExperience,
            specialties: row.specialties,
            languages: row.languages,
            certificates: certificates.sorted { $0.issuedAt > $1.issuedAt },
            portfolio: portfolio.sorted { $0.createdAt > $1.createdAt },
            instagramHandle: row.instagramHandle,
            tikTokHandle: row.tiktokHandle,
            rating: row.rating,
            reviewCount: row.reviewCount,
            averageResponseMinutes: row.averageResponseMinutes,
            isFreelancer: row.isFreelancer,
            serviceIDs: (row.professionalServices?.values ?? []).map { SalonService.ID($0.serviceID) }
        )
    }

    private static func makeReview(_ row: ReviewRow) throws -> Review {
        Review(
            id: Review.ID(row.id),
            salonID: Salon.ID(row.salonID),
            professionalID: row.professionalID.map { Professional.ID($0) },
            authorID: User.ID(row.authorID),
            authorName: row.authorName,
            authorAvatarURL: row.authorAvatarURL.flatMap(URL.init(string:)),
            rating: row.rating,
            text: row.text,
            photoURLs: row.photoURLs.compactMap(URL.init(string:)),
            videoURLs: row.videoURLs.compactMap(URL.init(string:)),
            verifiedAppointmentID: row.verifiedAppointmentID.map { Appointment.ID($0) },
            likeCount: row.likeCount,
            likedByMe: !(row.reviewLikes?.values ?? []).isEmpty,
            ownerResponse: row.ownerResponse,
            ownerRespondedAt: SupabaseTimestamp.optionalDate(from: row.ownerRespondedAt),
            moderation: Review.ModerationStatus(rawValue: row.moderation) ?? .pending,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }
}

// MARK: - Rows

extension SupabaseSalonRepository {
    /// A `salons` row plus its embedded hours and prepayment policy.
    fileprivate struct SalonRow: Decodable, Sendable {
        let id: UUID
        let organizationID: UUID?
        let name: String
        let tagline: String?
        let about: String
        let categories: [String]
        let amenities: [String]
        let languages: [String]
        let street: String
        let city: String
        let postalCode: String
        let country: String
        let latitude: Double
        let longitude: Double
        let phone: String?
        let email: String?
        let heroImageURL: String?
        let heroVideoURL: String?
        let galleryURLs: [String]
        let instagramHandle: String?
        let tiktokHandle: String?
        let virtualTourURL: String?
        let certificates: [String]
        let awards: [String]
        let currency: String
        let rating: Double
        let reviewCount: Int
        let isVerified: Bool
        let policyFreeCancellationHours: Int
        let policyLateCancellationPercent: Int
        let policyNoShowPercent: Int
        let policyLateGraceMinutes: Int
        let policyChildrenAllowed: Bool
        let policyNotes: String?
        let createdAt: String
        let salonOpeningHours: SupabaseEmbedded<OpeningHoursRow>?
        let prepaymentPolicies: SupabaseEmbedded<PrepaymentPolicyRow>?
    }

    /// A `salon_opening_hours` row.
    fileprivate struct OpeningHoursRow: Decodable, Sendable {
        let weekday: Int
        let openMinutes: Int
        let closeMinutes: Int
    }

    /// A `prepayment_policies` row.
    fileprivate struct PrepaymentPolicyRow: Decodable, Sendable {
        let offeredPercents: [Int]
        let fullPrepaymentDiscountPercent: Int
        let rewardPointsMultiplier: Int
        let cashbackPercent: Int
        let grantsPriorityBooking: Bool
    }

    /// A `services` row plus its embedded add-ons.
    fileprivate struct ServiceRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID?
        let name: String
        let details: String
        let category: String
        let priceAmount: Decimal
        let priceCurrency: String
        let isStartingPrice: Bool
        let durationMinutes: Int
        let preparationMinutes: Int
        let cleanupMinutes: Int
        let bufferMinutes: Int
        let imageURL: String?
        let isActive: Bool
        let requiresPrepayment: Bool
        let serviceAddOns: SupabaseEmbedded<ServiceAddOnRow>?
    }

    /// A `service_add_ons` row.
    fileprivate struct ServiceAddOnRow: Decodable, Sendable {
        let id: UUID
        let name: String
        let priceAmount: Decimal
        let priceCurrency: String
        let extraMinutes: Int
        let isActive: Bool
    }

    /// A `professionals` row plus its embedded child tables.
    fileprivate struct ProfessionalRow: Decodable, Sendable {
        let id: UUID
        let userID: UUID?
        let salonID: UUID?
        let displayName: String
        let title: String
        let biography: String
        let photoURL: String?
        let yearsOfExperience: Int
        let specialties: [String]
        let languages: [String]
        let instagramHandle: String?
        let tiktokHandle: String?
        let rating: Double
        let reviewCount: Int
        let averageResponseMinutes: Int?
        let isFreelancer: Bool
        let certificates: SupabaseEmbedded<CertificateRow>?
        let portfolioItems: SupabaseEmbedded<PortfolioItemRow>?
        let professionalServices: SupabaseEmbedded<ProfessionalServiceRow>?
    }

    /// A `certificates` row.
    fileprivate struct CertificateRow: Decodable, Sendable {
        let id: UUID
        let title: String
        let issuer: String
        let issuedAt: String
        let documentURL: String?
    }

    /// A `portfolio_items` row.
    fileprivate struct PortfolioItemRow: Decodable, Sendable {
        let id: UUID
        let kind: String
        let mediaURL: String
        let beforeURL: String?
        let caption: String?
        let createdAt: String
    }

    /// A `professional_services` join row.
    fileprivate struct ProfessionalServiceRow: Decodable, Sendable {
        let serviceID: UUID
    }

    /// A `reviews` row plus the caller's own like, if any.
    fileprivate struct ReviewRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let professionalID: UUID?
        let authorID: UUID
        let authorName: String
        let authorAvatarURL: String?
        let rating: Int
        let text: String
        let photoURLs: [String]
        let videoURLs: [String]
        let verifiedAppointmentID: UUID?
        let likeCount: Int
        let ownerResponse: String?
        let ownerRespondedAt: String?
        let moderation: String
        let createdAt: String
        let reviewLikes: SupabaseEmbedded<ReviewLikeRow>?
    }

    /// A `review_likes` row, scoped by RLS to the caller.
    fileprivate struct ReviewLikeRow: Decodable, Sendable {
        let userID: UUID
    }

    /// The columns a new review supplies; everything else is server-owned.
    fileprivate struct ReviewInsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let professionalID: UUID?
        let authorID: UUID
        let authorName: String
        let authorAvatarURL: String?
        let rating: Int
        let text: String
        let photoURLs: [String]
        let videoURLs: [String]
        let verifiedAppointmentID: UUID?
    }

    /// A like, written as `(review_id, user_id)`.
    fileprivate struct ReviewLikeInsert: Encodable, Sendable {
        let reviewID: UUID
        let userID: UUID
    }
}
