import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Outcome of a service-resolution pass, mapped to `Sendable` values before it
/// crosses back onto the main actor. Declared at file scope, outside the
/// `@MainActor` model, so the nonisolated fetch can build it freely.
private enum ResolutionOutcome: Sendable {
    /// The services behind a package, in the package's own order.
    case loaded([SalonService])
    /// The resolution failed, with copy ready for the card.
    case failed(String)
}

/// Screen model backing ``PackagesView``.
///
/// Packages are sold as a bundle price against a regular price, so the two
/// numbers must always be right together — the package list is the screen's
/// spine and fails as a whole. The services *inside* a package resolve lazily
/// when a card is expanded: most clients open one or two, and fetching every
/// service of every package upfront would waste a round trip per service for
/// content nobody looked at.
@Observable
@MainActor
final class PackagesModel {
    /// Resolution state of one package's included services.
    enum ServiceResolution: Equatable, Sendable {
        /// Not requested yet.
        case idle
        /// Fetching.
        case loading
        /// Resolved, in the package's own order.
        case loaded([SalonService])
        /// Failed, with warm copy and a retry available.
        case failed(String)
    }

    // MARK: - State

    private(set) var phase: MembershipsPhase = .loading
    /// Packages on sale, biggest saving first.
    private(set) var packages: [ServicePackage] = []
    /// Salon names behind the packages, for cross-salon lists.
    private(set) var salonNames: [Salon.ID: String] = [:]
    /// Per-package resolution of the included services.
    private(set) var resolutions: [ServicePackage.ID: ServiceResolution] = [:]
    /// Package whose purchase is in flight.
    private(set) var purchasingPackageID: ServicePackage.ID?
    /// `true` when nobody is signed in — packages stay browsable, buying does not.
    private(set) var isGuest = false
    /// Transient feedback (purchase failed…).
    var toast: PRVToast?

    private var hasLoadedOnce = false

    /// Creates an empty model. All data arrives through ``load(for:salonID:using:)``.
    init() {}

    // MARK: - Derived

    /// `true` when there is nothing on sale.
    var isEmpty: Bool { packages.isEmpty }

    /// Salon name behind a package, when known.
    func salonName(for package: ServicePackage) -> String? { salonNames[package.salonID] }

    /// Resolution state for a package's included services.
    func resolution(for package: ServicePackage) -> ServiceResolution {
        resolutions[package.id] ?? .idle
    }

    /// Whether this package's buy button should show a spinner.
    func isPurchasing(_ package: ServicePackage) -> Bool {
        purchasingPackageID == package.id
    }

    // MARK: - Loading

    /// Loads the packages on sale.
    ///
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests.
    ///   - salonID: Restricts packages to one salon; `nil` shows every package.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, salonID: Salon.ID?, using deps: PRVDependencies) async {
        isGuest = user == nil
        if !hasLoadedOnce { phase = .loading }

        do {
            let loaded = try await deps.memberships.packages(salonID: salonID)
            packages = loaded
                .filter(\.isActive)
                .sorted { $0.savings.amount > $1.savings.amount }
            // Cards that were open before a refresh keep their contents; the
            // rest are dropped so a removed package can't leak stale services.
            let liveIDs = Set(packages.map(\.id))
            resolutions = resolutions.filter { liveIDs.contains($0.key) }
            phase = .loaded
            hasLoadedOnce = true
        } catch {
            let message = MembershipsFormatting.friendlyError(error, subject: "Packages")
            if hasLoadedOnce {
                toast = .warning(message)
                phase = .loaded
            } else {
                phase = .failed(message)
            }
        }

        await loadSalonNames(using: deps)
    }

    /// Fills in the names of the salons behind the packages.
    private func loadSalonNames(using deps: PRVDependencies) async {
        let missing = Set(packages.map(\.salonID)).subtracting(salonNames.keys)
        guard !missing.isEmpty else { return }
        let fetched = await Self.fetchSalonNames(missing, using: deps)
        salonNames.merge(fetched) { _, new in new }
    }

    // MARK: - Included services

    /// Resolves the services inside a package, once. Call it when a card
    /// expands; repeated calls while loading or after success are no-ops, so
    /// toggling a card open and shut never refetches.
    func resolveServices(for package: ServicePackage, using deps: PRVDependencies) async {
        switch resolution(for: package) {
        case .loading, .loaded:
            return
        case .idle, .failed:
            break
        }

        guard !package.serviceIDs.isEmpty else {
            resolutions[package.id] = .loaded([])
            return
        }

        resolutions[package.id] = .loading
        switch await Self.fetchServices(package.serviceIDs, using: deps) {
        case .loaded(let services):
            resolutions[package.id] = .loaded(services)
        case .failed(let message):
            resolutions[package.id] = .failed(message)
        }
    }

    /// Forces a re-resolution after a failure.
    func retryServices(for package: ServicePackage, using deps: PRVDependencies) async {
        resolutions[package.id] = .idle
        await resolveServices(for: package, using: deps)
    }

    // MARK: - Purchasing

    /// Turns a package into a payable order.
    ///
    /// This model deliberately stops at the order: payment belongs to the
    /// checkout feature, which the caller reaches through `AppRouter`.
    ///
    /// - Returns: The created order, or `nil` when it could not be created.
    func purchase(_ package: ServicePackage, for user: User, using deps: PRVDependencies) async -> Order? {
        guard purchasingPackageID == nil else { return nil }
        purchasingPackageID = package.id
        defer { purchasingPackageID = nil }

        do {
            let order = try await deps.memberships.purchasePackage(packageID: package.id, userID: user.id)
            PRVHaptics.success()
            return order
        } catch {
            PRVHaptics.error()
            toast = .error(MembershipsFormatting.friendlyError(error, subject: package.name))
            return nil
        }
    }

    // MARK: - Fetching helpers

    /// Resolves service IDs concurrently, then restores the package's own
    /// order — a bundle reads as a sequence ("trial, then the day itself"),
    /// and completion order is meaningless to the client.
    ///
    /// One missing service fails the whole list: a bundle that silently drops
    /// a treatment would misrepresent what someone is buying.
    private nonisolated static func fetchServices(
        _ serviceIDs: [SalonService.ID],
        using deps: PRVDependencies
    ) async -> ResolutionOutcome {
        do {
            let resolved = try await withThrowingTaskGroup(of: SalonService.self) { group in
                for serviceID in Set(serviceIDs) {
                    group.addTask { try await deps.salons.service(id: serviceID) }
                }
                var services: [SalonService.ID: SalonService] = [:]
                for try await service in group {
                    services[service.id] = service
                }
                return services
            }
            return .loaded(serviceIDs.compactMap { resolved[$0] })
        } catch {
            return .failed(MembershipsFormatting.friendlyError(error, subject: "These services"))
        }
    }

    /// Resolves salon names concurrently; failures simply stay unnamed.
    private nonisolated static func fetchSalonNames(
        _ salonIDs: Set<Salon.ID>,
        using deps: PRVDependencies
    ) async -> [Salon.ID: String] {
        await withTaskGroup(of: (Salon.ID, String)?.self) { group in
            for salonID in salonIDs {
                group.addTask {
                    guard let salon = try? await deps.salons.salon(id: salonID) else { return nil }
                    return (salon.id, salon.name)
                }
            }
            var names: [Salon.ID: String] = [:]
            for await pair in group {
                if let pair { names[pair.0] = pair.1 }
            }
            return names
        }
    }
}
