import Foundation
import Observation
import PRVFoundation
import PRVModels
import PRVNetworking

/// Loading lifecycle of one independently fetched home-screen section.
///
/// Every section owns its own phase so a slow or failing repository never
/// blocks the rest of the screen: each renders a skeleton, its content, an
/// inline error, or nothing at all.
enum HomeSectionPhase<Value: Sendable>: Sendable {
    /// The section is fetching and should render a skeleton.
    case loading
    /// The section loaded successfully.
    case loaded(Value)
    /// The fetch failed with a friendly, human-readable message.
    case failed(String)
    /// The section does not apply to this session (e.g. guests have no
    /// loyalty status) and should not be rendered at all.
    case unavailable

    /// The loaded value, when available.
    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// Whether the section is currently fetching.
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension HomeSectionPhase: Equatable where Value: Equatable {}

/// Screen model backing `HomeView`.
///
/// Loads every section concurrently with `async let` so the home screen
/// assembles as fast as the slowest repository — never sequentially — and
/// keeps per-section state so failures degrade gracefully.
@Observable
@MainActor
final class HomeModel {
    /// The upcoming-appointment hero: the next active appointment plus its
    /// salon (fetched for directions and imagery; `nil` if that lookup fails).
    struct UpcomingHero: Hashable, Sendable {
        var appointment: Appointment
        var salon: Salon?
    }

    /// Compact Beauty Wallet summary for the snapshot tile.
    struct WalletSnapshot: Hashable, Sendable {
        var storeCredit: Money
        var points: Int
    }

    // MARK: - Section state

    /// `.loaded(nil)` means "signed in, but nothing booked" — the friendly
    /// empty hero renders in that case.
    private(set) var heroPhase: HomeSectionPhase<UpcomingHero?> = .loading
    private(set) var trendingPhase: HomeSectionPhase<[Salon]> = .loading
    private(set) var nearbyPhase: HomeSectionPhase<[Salon]> = .loading
    private(set) var recentlyViewedPhase: HomeSectionPhase<[Salon]> = .loading
    private(set) var loyaltyPhase: HomeSectionPhase<LoyaltyProfile> = .loading
    private(set) var packagesPhase: HomeSectionPhase<[ServicePackage]> = .loading
    private(set) var walletPhase: HomeSectionPhase<WalletSnapshot> = .loading

    /// Unread notification count feeding the bell badge.
    private(set) var unreadNotificationCount = 0

    /// Set after the first full load; later refreshes keep stale content on
    /// screen instead of flashing skeletons.
    private(set) var hasLoadedOnce = false

    // MARK: - Loading

    /// Loads every home section concurrently. Safe to call repeatedly
    /// (pull-to-refresh, sign-in changes); sections update independently.
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests (personal sections
    ///     become `.unavailable`).
    ///   - deps: Repository container from the environment.
    func load(for user: User?, using deps: PRVDependencies) async {
        if !hasLoadedOnce {
            heroPhase = .loading
            trendingPhase = .loading
            nearbyPhase = .loading
            recentlyViewedPhase = .loading
            packagesPhase = .loading
            loyaltyPhase = user == nil ? .unavailable : .loading
            walletPhase = user == nil ? .unavailable : .loading
        }

        // Public discovery sections — fetched for everyone, concurrently.
        async let trendingTask = deps.salons.trendingSalons()
        async let nearbyTask = deps.salons.nearbySalons(nil)
        async let recentTask = deps.salons.recentlyViewedSalons()
        async let packagesTask = deps.memberships.packages(salonID: nil)

        do { trendingPhase = .loaded(try await trendingTask) }
        catch { trendingPhase = .failed(Self.friendlyMessage(for: error)) }

        do { nearbyPhase = .loaded(try await nearbyTask) }
        catch { nearbyPhase = .failed(Self.friendlyMessage(for: error)) }

        do { recentlyViewedPhase = .loaded(try await recentTask) }
        catch { recentlyViewedPhase = .failed(Self.friendlyMessage(for: error)) }

        do { packagesPhase = .loaded(try await packagesTask) }
        catch { packagesPhase = .failed(Self.friendlyMessage(for: error)) }

        // Personal sections — only for signed-in users.
        if let user {
            await loadPersonalSections(for: user, using: deps)
        } else {
            heroPhase = .loaded(nil)
            loyaltyPhase = .unavailable
            walletPhase = .unavailable
            unreadNotificationCount = 0
        }

        hasLoadedOnce = true
    }

    /// Fetches the signed-in user's appointment hero, loyalty status,
    /// notifications badge, and wallet snapshot — all concurrently.
    private func loadPersonalSections(for user: User, using deps: PRVDependencies) async {
        async let appointmentsTask = deps.appointments.appointments(clientID: user.id)
        async let loyaltyTask = deps.loyalty.profile(userID: user.id)
        async let notificationsTask = deps.notifications.notifications(userID: user.id)
        async let creditTask = deps.payments.storeCreditBalance(userID: user.id)

        do {
            let appointments = try await appointmentsTask
            if let next = Self.nextUpcomingAppointment(in: appointments, now: .now) {
                // Salon enriches the hero (directions, imagery); a failed
                // lookup degrades to a salon-name-only card, never an error.
                let salon = try? await deps.salons.salon(id: next.salonID)
                heroPhase = .loaded(UpcomingHero(appointment: next, salon: salon))
            } else {
                heroPhase = .loaded(nil)
            }
        } catch {
            heroPhase = .failed(Self.friendlyMessage(for: error))
        }

        do { loyaltyPhase = .loaded(try await loyaltyTask) }
        catch { loyaltyPhase = .failed(Self.friendlyMessage(for: error)) }

        do {
            let notifications = try await notificationsTask
            unreadNotificationCount = notifications.count(where: { !$0.isRead })
        } catch {
            // A missing badge is not worth an error surface.
            unreadNotificationCount = 0
        }

        do {
            let credit = try await creditTask
            walletPhase = .loaded(
                WalletSnapshot(
                    storeCredit: credit,
                    points: loyaltyPhase.value?.spendablePoints ?? 0
                )
            )
        } catch {
            walletPhase = .failed(Self.friendlyMessage(for: error))
        }
    }

    // MARK: - Helpers

    /// The next appointment worth headlining: still active and not yet over,
    /// earliest start first.
    nonisolated static func nextUpcomingAppointment(in appointments: [Appointment], now: Date) -> Appointment? {
        appointments
            .filter { $0.status.isActive && ($0.end ?? .distantPast) > now }
            .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Maps transport errors to warm, actionable copy — never raw codes.
    nonisolated static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Check your connection and pull to refresh."
        case .rateLimited:
            "Too many requests. Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "Please sign in again to see this."
        case .notFound, .conflict, .server, .decoding:
            "We couldn't load this right now. Pull to refresh to try again."
        }
    }
}
