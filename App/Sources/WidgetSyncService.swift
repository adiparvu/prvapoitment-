import Foundation
import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking

/// Keeps the home-screen widgets and the booking Live Activity in step with
/// the app's data.
///
/// The widget extension is sandboxed away from the network and the
/// repositories, so it can only render what the app has published into the
/// shared app group. `PRVWidgetSnapshot` defines that document and
/// `BookingLiveActivityController` owns the Live Activity; this service is the
/// piece that decides *when* to publish and *what* the current state is.
///
/// Call ``refresh(using:for:)`` whenever the underlying facts change — launch,
/// foreground, sign-in, a new booking, a cancellation, a loyalty award — and
/// ``signedOut()`` when the session ends.
@MainActor
public enum WidgetSyncService {
    /// Rebuilds the shared snapshot and reconciles the Live Activity.
    ///
    /// Reads are best-effort: a failure to load one section publishes the
    /// other rather than leaving widgets stale, because a widget showing
    /// yesterday's appointment is worse than one showing none.
    /// - Parameters:
    ///   - deps: The repository container to read through.
    ///   - user: The signed-in client. Passing `nil` clears the snapshot.
    public static func refresh(using deps: PRVDependencies, for user: User?) async {
        guard let user else {
            signedOut()
            return
        }

        async let appointmentsTask = try? await deps.appointments.appointments(clientID: user.id)
        async let loyaltyTask = try? await deps.loyalty.profile(userID: user.id)

        let appointments = await appointmentsTask ?? []
        let profile = await loyaltyTask

        let upcoming = nextAppointment(in: appointments)
        let snapshot = PRVWidgetSnapshot(
            nextAppointment: upcoming.flatMap(PRVWidgetSnapshot.NextAppointment.init(appointment:)),
            loyalty: profile.map(PRVWidgetSnapshot.Loyalty.init(profile:))
        )

        if !snapshot.write() {
            // The app group entitlement is the only realistic cause; widgets
            // fall back to their placeholder, so this is not user-facing.
            PRVLog.app.notice("Widget snapshot could not be published")
        }

        await reconcileLiveActivity(with: upcoming)
    }

    /// Clears everything the widgets and Lock Screen show for a signed-out
    /// device: no appointment details survive sign-out.
    public static func signedOut() {
        PRVWidgetSnapshot.clear()
        Task { await BookingLiveActivityController.endAll() }
    }

    // MARK: - Live Activity

    /// How close an appointment must be before it earns a Live Activity.
    ///
    /// Four hours covers "leave soon" through the visit itself without
    /// occupying the Lock Screen for a booking days away.
    private static let liveActivityLeadTime: TimeInterval = 4 * 60 * 60

    /// Starts, updates, or ends the booking Live Activity so at most one runs
    /// and it always describes the visit actually in play.
    private static func reconcileLiveActivity(with appointment: Appointment?) async {
        guard let appointment,
              let start = appointment.start,
              let end = appointment.end,
              appointment.status.isActive
        else {
            await BookingLiveActivityController.endAll()
            return
        }

        // Outside the window the activity is either premature or finished.
        let now = Date.now
        guard start.timeIntervalSince(now) <= liveActivityLeadTime, now < end else {
            if now >= end {
                await BookingLiveActivityController.end(appointmentID: appointment.id.rawValue)
            }
            return
        }

        let primary = appointment.items.min { $0.start < $1.start }
        let attributes = BookingActivityAttributes(
            salonName: appointment.salonName,
            serviceName: primary?.serviceName ?? "Your appointment",
            appointmentID: appointment.id.rawValue
        )
        let state = BookingActivityAttributes.ContentState(
            statusText: appointment.status.displayName,
            professionalName: primary?.professionalName ?? "Your professional",
            start: start,
            end: end
        )
        await BookingLiveActivityController.start(attributes: attributes, state: state)
    }

    /// The soonest active appointment that has not finished yet.
    private static func nextAppointment(in appointments: [Appointment]) -> Appointment? {
        let now = Date.now
        return appointments
            .filter { $0.status.isActive && ($0.end ?? .distantPast) > now }
            .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }
}

extension View {
    /// Republishes widget and Live Activity state whenever the session's user
    /// changes or the app returns to the foreground.
    ///
    /// Attached once at the app root so no feature has to remember to do it.
    func prvWidgetSync(session: UserSession, dependencies: PRVDependencies) -> some View {
        modifier(WidgetSyncModifier(session: session, dependencies: dependencies))
    }
}

/// Drives ``WidgetSyncService`` from session and scene-phase changes.
private struct WidgetSyncModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    let session: UserSession
    let dependencies: PRVDependencies

    func body(content: Content) -> some View {
        content
            .task(id: session.currentUser?.id) {
                await WidgetSyncService.refresh(using: dependencies, for: session.currentUser)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await WidgetSyncService.refresh(using: dependencies, for: session.currentUser)
                }
            }
    }
}
