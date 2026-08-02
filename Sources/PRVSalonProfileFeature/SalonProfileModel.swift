import Foundation
import Observation
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The salon profile's content sections, shown behind the sticky glass
/// segmented control.
///
/// Public so callers outside the module — notably the app shell resolving a
/// `.reviews(salonID:)` deep link — can open the profile on a chosen section.
public enum SalonProfileSection: String, CaseIterable, Hashable, Sendable {
    case services
    case team
    case gallery
    case about
    case reviews

    /// Segment label.
    public var title: String {
        switch self {
        case .services: "Services"
        case .team: "Team"
        case .gallery: "Gallery"
        case .about: "About"
        case .reviews: "Reviews"
        }
    }
}

/// Services grouped under one business category for the Services section.
struct ServiceGroup: Identifiable, Hashable, Sendable {
    var category: BusinessCategory
    var services: [SalonService]
    var id: String { category.rawValue }
}

/// Screen model backing `SalonProfileView`: loads the salon with its
/// services, team, and reviews in parallel; owns the add-to-booking
/// selection state (services + add-ons) that feeds the floating "Book Now"
/// bar; and performs review interactions (like, report, submit).
@Observable
@MainActor
final class SalonProfileModel {
    /// Lifecycle of the initial load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// The salon being displayed.
    let salonID: Salon.ID

    private(set) var phase: Phase = .loading
    private(set) var salon: Salon?
    private(set) var services: [SalonService] = []
    private(set) var professionals: [Professional] = []
    private(set) var reviews: [Review] = []

    /// Currently visible content section.
    var section: SalonProfileSection = .services
    /// Services the client has added to the pending booking.
    private(set) var selectedServiceIDs: Set<SalonService.ID> = []
    /// Selected add-ons, keyed by their parent service.
    private(set) var selectedAddOnIDs: [SalonService.ID: Set<ServiceAddOn.ID>] = [:]
    /// Whether the "Write a review" sheet is presented.
    var isWritingReview = false
    /// Transient feedback (review submitted, report received, errors).
    var toast: PRVToast?

    /// A service the profile should surface on open, arriving from a
    /// `.service(_:salonID:)` deep link. Pre-selected once services load, so
    /// the booking bar already carries it.
    private let linkedServiceID: SalonService.ID?

    /// Creates the model for one salon, optionally opening on a given section
    /// with one service already selected.
    init(
        salonID: Salon.ID,
        section: SalonProfileSection = .services,
        linkedServiceID: SalonService.ID? = nil
    ) {
        self.salonID = salonID
        self.section = section
        self.linkedServiceID = linkedServiceID
    }

    // MARK: - Loading

    /// Loads the salon, services, team, and reviews in parallel, then marks
    /// the salon as recently viewed. Safe to call again to retry.
    func load(using deps: PRVDependencies) async {
        phase = .loading
        do {
            async let salonTask = deps.salons.salon(id: salonID)
            async let servicesTask = deps.salons.services(salonID: salonID)
            async let professionalsTask = deps.salons.professionals(salonID: salonID)
            async let reviewsTask = deps.salons.reviews(salonID: salonID)

            salon = try await salonTask
            services = try await servicesTask.filter(\.isActive)
            professionals = try await professionalsTask
            reviews = try await reviewsTask.filter { $0.moderation != .removed }
            // A service arriving from a deep link is selected once the menu is
            // known, so the "Book Now" bar opens already carrying it.
            if let linkedServiceID, services.contains(where: { $0.id == linkedServiceID }) {
                selectedServiceIDs.insert(linkedServiceID)
            }
            phase = .loaded

            await deps.salons.markViewed(salonID: salonID)
        } catch {
            PRVLog.ui.error("Salon profile load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(ProfileFormatting.friendlyError(error, subject: "This salon"))
        }
    }

    // MARK: - Service selection

    /// Services grouped by category, categories and services alphabetized
    /// for a stable, scannable menu.
    var groupedServices: [ServiceGroup] {
        services
            .grouped { $0.category }
            .map { ServiceGroup(category: $0.key, services: $0.value.sorted(by: \.name)) }
            .sorted { $0.category.displayName < $1.category.displayName }
    }

    /// Whether the given service is in the pending booking.
    func isSelected(_ service: SalonService) -> Bool {
        selectedServiceIDs.contains(service.id)
    }

    /// Whether the given add-on of a service is in the pending booking.
    func isSelected(_ addOn: ServiceAddOn, of service: SalonService) -> Bool {
        selectedAddOnIDs[service.id, default: []].contains(addOn.id)
    }

    /// Adds or removes a service from the pending booking. Removing a
    /// service also clears its selected add-ons.
    func toggleService(_ service: SalonService) {
        if selectedServiceIDs.remove(service.id) != nil {
            selectedAddOnIDs[service.id] = nil
            PRVHaptics.tap()
        } else {
            selectedServiceIDs.insert(service.id)
            PRVHaptics.impact()
        }
    }

    /// Toggles an add-on. Selecting an add-on for an unselected service
    /// selects the service too, so the booking bar always stays coherent.
    func toggleAddOn(_ addOn: ServiceAddOn, of service: SalonService) {
        var addOns = selectedAddOnIDs[service.id] ?? []
        if addOns.remove(addOn.id) == nil {
            addOns.insert(addOn.id)
            selectedServiceIDs.insert(service.id)
            PRVHaptics.impact()
        } else {
            PRVHaptics.tap()
        }
        selectedAddOnIDs[service.id] = addOns
    }

    /// The selected services in menu order (stable for the booking route).
    var selectedServices: [SalonService] {
        services.filter { selectedServiceIDs.contains($0.id) }
    }

    /// Number of selected services.
    var selectedCount: Int { selectedServiceIDs.count }

    /// Sum of selected services and add-ons, in the salon's currency;
    /// `nil` while nothing is selected.
    var totalPrice: Money? {
        let selected = selectedServices
        guard !selected.isEmpty, let salon else { return nil }
        var total = Money.zero(salon.currency)
        for service in selected {
            total = total + service.price
            for addOn in service.addOns where isSelected(addOn, of: service) {
                total = total + addOn.price
            }
        }
        return total
    }

    /// Total treatment time of the selection, add-ons included.
    var totalDurationMinutes: Int {
        selectedServices.reduce(0) { partial, service in
            let addOnMinutes = service.addOns
                .filter { isSelected($0, of: service) }
                .reduce(0) { $0 + $1.extraMinutes }
            return partial + service.durationMinutes + addOnMinutes
        }
    }

    // MARK: - Reviews

    /// Reviews suitable for display (approved, or pending moderation).
    var visibleReviews: [Review] {
        reviews.filter { $0.moderation == .approved || $0.moderation == .pending }
    }

    /// Number of visible reviews with the given star rating (1…5).
    func reviewCount(stars: Int) -> Int {
        visibleReviews.filter { $0.rating == stars }.count
    }

    /// Share (0…1) of visible reviews with the given star rating.
    func reviewFraction(stars: Int) -> Double {
        let total = visibleReviews.count
        guard total > 0 else { return 0 }
        return Double(reviewCount(stars: stars)) / Double(total)
    }

    /// Toggles the current user's like on a review and reflects the
    /// server-updated counts.
    func toggleLike(on review: Review, using deps: PRVDependencies) async {
        PRVHaptics.tap()
        do {
            let updated = try await deps.salons.toggleReviewLike(id: review.id)
            if let index = reviews.firstIndex(where: { $0.id == updated.id }) {
                reviews[index] = updated
            }
        } catch {
            toast = .error("Couldn't update your like. Please try again.")
        }
    }

    /// Records an abuse report for a review. Moderation happens server-side;
    /// here we acknowledge the report immediately.
    func report(_ review: Review) {
        PRVLog.ui.info("Review reported: \(review.id.description, privacy: .public)")
        toast = .info("Thanks — our team will review this shortly.")
    }

    /// Submits a new review by the given author. Returns `true` on success
    /// so the sheet can dismiss itself.
    func submitReview(
        rating: Int,
        text: String,
        author: User,
        using deps: PRVDependencies
    ) async -> Bool {
        let review = Review(
            salonID: salonID,
            authorID: author.id,
            authorName: author.fullName,
            authorAvatarURL: author.avatarURL,
            rating: rating,
            text: text
        )
        do {
            let saved = try await deps.salons.submitReview(review)
            reviews.insert(saved, at: 0)
            toast = .success("Thanks for sharing your experience")
            return true
        } catch {
            toast = .error("Couldn't submit your review. Please try again.")
            return false
        }
    }
}
