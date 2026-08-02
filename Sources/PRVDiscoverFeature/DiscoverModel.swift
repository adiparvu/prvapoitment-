import Foundation
import Observation
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// An `AssistantRecommendation` with its referenced entities resolved into
/// full models, ready to render inline (service, salon, and pro cards).
struct ResolvedRecommendation: Hashable, Sendable {
    var recommendation: AssistantRecommendation
    var services: [SalonService]
    var salons: [Salon]
    var professionals: [Professional]
}

/// Screen model backing `DiscoverView`: debounced natural-language search,
/// structured filters driving `SalonSearchQuery`, sort, list/map mode, and
/// the inline "Ask AI" flow through the Beauty Assistant.
@Observable
@MainActor
final class DiscoverModel {
    /// Lifecycle of the inline Beauty Assistant request.
    enum AssistantPhase: Equatable {
        case idle
        case thinking
        case answered(ResolvedRecommendation)
        case failed(String)
    }

    // MARK: - State

    /// Raw text bound to the search field. Mirrored into `query.text` when a
    /// search actually runs.
    var searchText = ""

    /// The structured query all filters and chips write into.
    private(set) var query = SalonSearchQuery()

    /// `nil` until the first search completes — the view shows skeletons.
    private(set) var results: [Salon]?

    /// True while a search is in flight (existing results stay on screen).
    private(set) var isSearching = false

    /// Friendly message for the last failed search, if any.
    private(set) var errorMessage: String?

    /// Whether the full filter sheet is presented.
    var isShowingFilters = false

    /// Toggles between the list of rich cards and the MapKit map.
    var isMapMode = false

    private(set) var assistantPhase: AssistantPhase = .idle

    /// Debounce/coalescing state.
    private var searchTask: Task<Void, Never>?
    private var assistantTask: Task<Void, Never>?
    private var searchGeneration = 0

    // MARK: - Derived

    /// The "Ask AI" affordance appears when the text reads like a sentence —
    /// more than three words — rather than a keyword.
    var looksLikeSentence: Bool {
        searchText.split(whereSeparator: \.isWhitespace).count > 3
    }

    /// Number of active structured filters, for the "Filters" chip badge.
    var activeFilterCount: Int { query.activeFilterCount }

    /// Distance display for a salon card: real kilometers when the query has
    /// an origin, otherwise `nil` (the card falls back to the address).
    func distanceText(to salon: Salon) -> String? {
        guard let origin = query.near else { return nil }
        let km = origin.distanceKm(to: salon.address.coordinate)
        return "\(km.formatted(.number.precision(.fractionLength(1)))) km"
    }

    // MARK: - Searching

    /// Runs the first search if nothing has loaded yet.
    func loadInitial(using deps: PRVDependencies) async {
        guard results == nil else { return }
        await performSearch(using: deps)
    }

    /// Debounces keystrokes: cancels any pending search and schedules a new
    /// one 300 ms out. Also resets a stale assistant answer, since it no
    /// longer matches what the user is typing.
    func scheduleSearch(using deps: PRVDependencies) {
        dismissAssistant()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return // Cancelled by a newer keystroke.
            }
            await self?.performSearch(using: deps)
        }
    }

    /// Searches immediately (submit key, filter changes), cancelling any
    /// pending debounce.
    func searchNow(using deps: PRVDependencies) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.performSearch(using: deps)
        }
    }

    private func performSearch(using deps: PRVDependencies) async {
        query.text = searchText.trimmed
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true

        do {
            let found = try await deps.salons.searchSalons(query)
            guard generation == searchGeneration else { return } // Stale.
            results = found
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = Self.friendlyMessage(for: error)
        }
        isSearching = false
    }

    // MARK: - Filters

    /// Replaces the whole query (filter sheet "Show Results") and re-searches.
    func apply(_ newQuery: SalonSearchQuery, using deps: PRVDependencies) {
        query = newQuery
        searchNow(using: deps)
    }

    /// Clears every structured filter, keeping the text and sort.
    func clearFilters(using deps: PRVDependencies) {
        var cleared = SalonSearchQuery()
        cleared.text = query.text
        cleared.sort = query.sort
        apply(cleared, using: deps)
    }

    func toggleCategory(_ category: BusinessCategory, using deps: PRVDependencies) {
        if let index = query.categories.firstIndex(of: category) {
            query.categories.remove(at: index)
        } else {
            query.categories.append(category)
        }
        searchNow(using: deps)
    }

    func toggleVerified(using deps: PRVDependencies) {
        query.verifiedOnly.toggle()
        searchNow(using: deps)
    }

    /// Toggles the quick minimum-rating chip (tapping the active value clears it).
    func toggleMinRating(_ value: Double, using deps: PRVDependencies) {
        query.minRating = query.minRating == value ? nil : value
        searchNow(using: deps)
    }

    /// Selects an availability window (tapping the active one returns to "any").
    func setAvailability(_ window: SalonSearchQuery.AvailabilityWindow, using deps: PRVDependencies) {
        query.availability = query.availability == window ? .anyTime : window
        searchNow(using: deps)
    }

    func setSort(_ sort: SalonSearchQuery.Sort, using deps: PRVDependencies) {
        guard query.sort != sort else { return }
        query.sort = sort
        searchNow(using: deps)
    }

    // MARK: - Ask AI

    /// Routes the current text through the Beauty Assistant, then resolves
    /// the recommendation's IDs into full models for inline rendering.
    func askAssistant(userID: User.ID, using deps: PRVDependencies) {
        let prompt = searchText.trimmed
        guard !prompt.isEmpty else { return }
        assistantTask?.cancel()
        assistantPhase = .thinking
        assistantTask = Task { [weak self] in
            do {
                let recommendation = try await deps.chat.askAssistant(prompt: prompt, userID: userID)
                let resolved = await Self.resolve(recommendation, using: deps)
                guard !Task.isCancelled else { return }
                self?.assistantPhase = .answered(resolved)
                PRVHaptics.success()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.assistantPhase = .failed(Self.friendlyMessage(for: error))
                PRVHaptics.error()
            }
        }
    }

    /// Dismisses any assistant answer or in-flight request.
    func dismissAssistant() {
        assistantTask?.cancel()
        assistantTask = nil
        if assistantPhase != .idle {
            assistantPhase = .idle
        }
    }

    /// Resolves recommendation IDs into models, concurrently per entity kind.
    /// Individual lookup failures are skipped — a partial answer beats none.
    private nonisolated static func resolve(
        _ recommendation: AssistantRecommendation,
        using deps: PRVDependencies
    ) async -> ResolvedRecommendation {
        async let services = fetchServices(recommendation.serviceIDs, using: deps)
        async let salons = fetchSalons(recommendation.salonIDs, using: deps)
        async let professionals = fetchProfessionals(recommendation.professionalIDs, using: deps)
        return await ResolvedRecommendation(
            recommendation: recommendation,
            services: services,
            salons: salons,
            professionals: professionals
        )
    }

    private nonisolated static func fetchServices(
        _ ids: [SalonService.ID],
        using deps: PRVDependencies
    ) async -> [SalonService] {
        var found: [SalonService] = []
        for id in ids {
            if let service = try? await deps.salons.service(id: id) {
                found.append(service)
            }
        }
        return found
    }

    private nonisolated static func fetchSalons(
        _ ids: [Salon.ID],
        using deps: PRVDependencies
    ) async -> [Salon] {
        var found: [Salon] = []
        for id in ids {
            if let salon = try? await deps.salons.salon(id: id) {
                found.append(salon)
            }
        }
        return found
    }

    private nonisolated static func fetchProfessionals(
        _ ids: [Professional.ID],
        using deps: PRVDependencies
    ) async -> [Professional] {
        var found: [Professional] = []
        for id in ids {
            if let professional = try? await deps.salons.professional(id: id) {
                found.append(professional)
            }
        }
        return found
    }

    // MARK: - Errors

    /// Maps transport errors to warm, actionable copy — never raw codes.
    nonisolated static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Check your connection and try again."
        case .rateLimited:
            "Too many requests. Take a breath and try again in a moment."
        case .unauthorized, .forbidden:
            "Please sign in again to continue searching."
        case .notFound, .conflict, .server, .decoding:
            "Search is momentarily unavailable. Please try again shortly."
        }
    }
}
