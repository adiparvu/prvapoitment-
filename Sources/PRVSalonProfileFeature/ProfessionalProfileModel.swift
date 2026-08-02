import Foundation
import Observation
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// Screen model backing `ProfessionalProfileView`: loads the professional,
/// their salon, reviews mentioning them, and a short availability preview
/// (their next open slots) used for the "Book with …" call to action.
@Observable
@MainActor
final class ProfessionalProfileModel {
    /// Lifecycle of the initial load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// The professional being displayed.
    let professionalID: Professional.ID

    private(set) var phase: Phase = .loading
    private(set) var professional: Professional?
    /// The salon they work at; `nil` for independent freelancers without a
    /// published location.
    private(set) var salon: Salon?
    /// Reviews that explicitly mention this professional.
    private(set) var reviews: [Review] = []
    /// The professional's next bookable slots (up to three).
    private(set) var nextSlots: [TimeSlot] = []
    /// Transient feedback (report received, errors).
    var toast: PRVToast?

    /// Creates the model for one professional.
    init(professionalID: Professional.ID) {
        self.professionalID = professionalID
    }

    /// Loads the professional, then their salon context, filtered reviews,
    /// and availability preview in parallel. Marks the salon as recently
    /// viewed. Safe to call again to retry.
    func load(using deps: PRVDependencies) async {
        phase = .loading
        do {
            let loaded = try await deps.salons.professional(id: professionalID)
            professional = loaded

            if let salonID = loaded.salonID {
                async let salonTask = deps.salons.salon(id: salonID)
                async let reviewsTask = deps.salons.reviews(salonID: salonID)

                salon = try await salonTask
                reviews = try await reviewsTask.filter {
                    $0.professionalID == professionalID && $0.moderation != .removed
                }

                await loadAvailability(salonID: salonID, professional: loaded, using: deps)
                await deps.salons.markViewed(salonID: salonID)
            }

            phase = .loaded
        } catch {
            PRVLog.ui.error("Professional profile load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(ProfileFormatting.friendlyError(error, subject: "This professional"))
        }
    }

    /// Fetches the availability preview. Failures here degrade gracefully
    /// to an empty preview instead of failing the whole screen.
    private func loadAvailability(
        salonID: Salon.ID,
        professional: Professional,
        using deps: PRVDependencies
    ) async {
        let request = AvailabilityRequest(
            salonID: salonID,
            serviceIDs: Array(professional.serviceIDs.prefix(1)),
            professionalID: professional.id,
            rangeStart: .now,
            rangeEnd: Date.now.adding(days: 14)
        )
        do {
            let slots = try await deps.appointments.availableSlots(request)
            nextSlots = Array(slots.sorted(by: \.start).prefix(3))
        } catch {
            PRVLog.ui.error("Availability preview failed: \(String(describing: error), privacy: .public)")
            nextSlots = []
        }
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

    /// Records an abuse report for a review and acknowledges it.
    func report(_ review: Review) {
        PRVLog.ui.info("Review reported: \(review.id.description, privacy: .public)")
        toast = .info("Thanks — our team will review this shortly.")
    }
}
