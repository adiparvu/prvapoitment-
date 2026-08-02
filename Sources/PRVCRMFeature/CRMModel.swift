import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model behind ``CRMView``.
///
/// Owns the searchable, sortable client book for one salon. Search runs through
/// the repository (`clients(salonID:searchText:)`) rather than filtering
/// locally, so it keeps working once the book outgrows a single page; the view
/// debounces keystrokes by rekeying its `.task`.
@Observable
@MainActor
final class CRMModel {
    // MARK: Inputs

    /// Live query text, sent to the repository.
    var searchText: String = ""
    /// Local ordering applied to whatever the repository returns.
    var sort: ClientSort = .lastVisit

    // MARK: State

    private(set) var phase: CRMPhase = .loading
    private(set) var clients: [ClientRecord] = []
    private(set) var hasLoadedOnce = false
    private(set) var isSaving = false

    var toast: PRVToast?

    // MARK: Derived

    /// The client book in the selected order.
    var sortedClients: [ClientRecord] {
        sort.apply(to: clients)
    }

    /// Whether the empty state should read as "no results" instead of
    /// "no clients yet".
    var isSearching: Bool { !searchText.isBlank }

    /// Lifetime spend across the loaded book.
    var totalSpend: Money {
        guard let first = clients.first else { return .zero() }
        return clients.dropFirst().reduce(first.totalSpend) { $0 + $1.totalSpend }
    }

    /// Clients added in the last 30 days.
    var newThisMonth: Int {
        let cutoff = Date.now.adding(days: -30)
        return clients.count { $0.createdAt >= cutoff }
    }

    /// Clients who have not been in for more than 90 days — the win-back list.
    var lapsedCount: Int {
        let cutoff = Date.now.adding(days: -90)
        return clients.count { ($0.lastVisitAt ?? .distantPast) < cutoff }
    }

    // MARK: Loading

    /// Loads the client book for a salon, applying the current search text.
    func load(salonID: Salon.ID, using deps: PRVDependencies) async {
        if !hasLoadedOnce { phase = .loading }
        do {
            clients = try await deps.crm.clients(salonID: salonID, searchText: searchText)
            phase = .loaded
        } catch {
            clients = []
            phase = .failed(CRMCopy.friendlyMessage(for: error))
        }
        hasLoadedOnce = true
    }

    // MARK: Mutations

    /// Creates or updates a client record and folds the result into the book.
    /// - Returns: `true` when the write succeeded.
    @discardableResult
    func upsert(_ record: ClientRecord, using deps: PRVDependencies) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        do {
            let saved = try await deps.crm.upsertClient(record)
            if let index = clients.firstIndex(where: { $0.id == saved.id }) {
                clients[index] = saved
            } else {
                clients.append(saved)
            }
            PRVHaptics.success()
            toast = .success("\(saved.fullName) added to your client book")
            return true
        } catch {
            PRVHaptics.error()
            toast = .error(CRMCopy.friendlyMessage(for: error))
            return false
        }
    }
}
