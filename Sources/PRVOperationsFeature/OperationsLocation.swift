import CoreLocation
import Foundation
import PRVModels

/// The outcome of a one-shot location request made when clocking in or out.
///
/// Clocking is never blocked by location: a denied or unavailable fix simply
/// records the entry without a coordinate, which the backend surfaces as an
/// unvalidated (no shield) time entry.
enum OperationsLocationFix: Equatable, Sendable {
    /// A usable fix; hand the coordinate to the team repository.
    case coordinate(GeoCoordinate)
    /// The person (or a device policy) declined location access.
    case denied
    /// Location is on but no fix arrived in time.
    case unavailable

    /// The coordinate to pass to `clockIn`/`clockOut`, if any.
    var coordinate: GeoCoordinate? {
        if case .coordinate(let value) = self { return value }
        return nil
    }

    /// Short caption explaining why an entry will not be GPS-validated.
    /// `nil` when a fix was obtained.
    var explanation: String? {
        switch self {
        case .coordinate: nil
        case .denied: "Location is off, so this entry isn't GPS-verified. Enable location in Settings to verify future ones."
        case .unavailable: "We couldn't get a location in time, so this entry isn't GPS-verified."
        }
    }
}

/// One-shot Core Location access for time tracking.
///
/// Uses the modern `CLLocationUpdate` async sequence rather than a delegate,
/// which keeps the whole path `Sendable` under strict concurrency. Starting the
/// sequence is what triggers the system's When-In-Use authorization prompt, so
/// no separate permission call is needed — the app's `Info.plist` must carry
/// `NSLocationWhenInUseUsageDescription`.
///
/// The request always finishes: the first fix, an explicit denial, or a
/// timeout, whichever lands first.
enum OperationsLocation {
    /// Requests a single coordinate, giving up after `timeout`.
    /// - Parameter timeout: How long to wait for the first fix. Defaults to 6s,
    ///   which is comfortably longer than a warm GPS fix and short enough that
    ///   the clock button never feels stuck.
    static func oneShot(timeout: Duration = .seconds(6)) async -> OperationsLocationFix {
        await withTaskGroup(of: OperationsLocationFix?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.default) {
                        if update.authorizationDenied
                            || update.authorizationDeniedGlobally
                            || update.authorizationRestricted {
                            return .denied
                        }
                        if let location = update.location {
                            return .coordinate(
                                GeoCoordinate(
                                    latitude: location.coordinate.latitude,
                                    longitude: location.coordinate.longitude
                                )
                            )
                        }
                        if update.locationUnavailable {
                            return .unavailable
                        }
                    }
                    return .unavailable
                } catch {
                    return .unavailable
                }
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unavailable
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .unavailable
        }
    }
}
