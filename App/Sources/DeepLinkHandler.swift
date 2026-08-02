import Foundation
import PRVFoundation
import PRVModels

/// Translates `prvbeauty://` URLs — from Live Activities, widgets, push
/// notifications, and marketing links — into `AppRoute` destinations.
///
/// Supported forms:
/// ```
/// prvbeauty://salon/<uuid>
/// prvbeauty://professional/<uuid>
/// prvbeauty://appointment/<uuid>
/// prvbeauty://booking/<salon-uuid>?services=<uuid>,<uuid>
/// prvbeauty://checkout/<order-uuid>
/// prvbeauty://conversation/<uuid>
/// prvbeauty://assistant
/// prvbeauty://wallet | loyalty | giftcards | notifications | settings
/// prvbeauty://memberships[/<salon-uuid>]
/// prvbeauty://packages[/<salon-uuid>]
/// ```
public enum DeepLinkHandler {
    public static let scheme = "prvbeauty"

    /// The tab bar a link is resolved against. Client and business users run
    /// different tab sets (`AppTab.clientTabs` / `AppTab.businessTabs`), so the
    /// same route has to land on a different tab depending on which experience
    /// is on screen.
    public enum Experience: String, Sendable, CaseIterable {
        case client
        case business
    }

    /// Parses a deep link, returning the route to open and the tab it belongs
    /// to. Returns `nil` for URLs this app does not handle.
    /// - Parameters:
    ///   - url: The incoming `prvbeauty://` URL.
    ///   - experience: The tab set currently on screen. The returned tab is
    ///     always a member of that set, so the selection matches a rendered
    ///     `Tab` and the pushed route lands on a navigation path that exists.
    public static func route(
        for url: URL,
        in experience: Experience = .client
    ) -> (route: AppRoute, tab: AppTab)? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // In `prvbeauty://salon/<uuid>` the host carries the verb and the
        // first path component carries the identifier.
        guard let verb = url.host()?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let identifier = components.first.flatMap(UUID.init(uuidString:))
        guard let destination = clientDestination(verb: verb, identifier: identifier, url: url)
        else { return nil }

        return (destination.route, resolvedTab(for: destination.tab, in: experience))
    }

    /// The canonical mapping, authored against the client tab set.
    private static func clientDestination(
        verb: String,
        identifier: UUID?,
        url: URL
    ) -> (route: AppRoute, tab: AppTab)? {
        switch verb {
        case "salon":
            guard let identifier else { return nil }
            return (.salon(Salon.ID(identifier)), .discover)
        case "professional":
            guard let identifier else { return nil }
            return (.professional(Professional.ID(identifier)), .discover)
        case "appointment":
            guard let identifier else { return nil }
            return (.appointment(Appointment.ID(identifier)), .appointments)
        case "booking":
            guard let identifier else { return nil }
            let serviceIDs = serviceIDs(from: url)
            return (.booking(salonID: Salon.ID(identifier), serviceIDs: serviceIDs), .appointments)
        case "checkout":
            guard let identifier else { return nil }
            return (.checkout(Order.ID(identifier)), .appointments)
        case "conversation":
            guard let identifier else { return nil }
            return (.conversation(Conversation.ID(identifier)), .chat)
        case "assistant":
            return (.beautyAssistant, .chat)
        case "wallet":
            return (.wallet, .wallet)
        case "loyalty":
            return (.loyalty, .wallet)
        case "giftcards":
            return (.giftCards, .wallet)
        case "memberships":
            return (.memberships(salonID: identifier.map(Salon.ID.init)), .wallet)
        case "packages":
            return (.packages(salonID: identifier.map(Salon.ID.init)), .discover)
        case "notifications":
            return (.notifications, .home)
        case "settings":
            return (.settings, .home)
        default:
            PRVLog.app.notice("Unhandled deep link verb: \(verb, privacy: .public)")
            return nil
        }
    }

    /// Re-homes a tab onto the set the active experience renders.
    ///
    /// A business user's tab bar has no Bookings, Discover, Wallet, or Home
    /// tab: leaving a link on one of those would select a value with no
    /// matching `Tab` *and* push the route onto a navigation path the business
    /// experience never builds, so the link would silently do nothing.
    /// Bookings becomes Calendar; everything without a business counterpart
    /// falls back to the Dashboard.
    private static func resolvedTab(for tab: AppTab, in experience: Experience) -> AppTab {
        switch experience {
        case .client:
            return AppTab.clientTabs.contains(tab) ? tab : .home
        case .business:
            if AppTab.businessTabs.contains(tab) { return tab }
            return tab == .appointments ? .calendar : .dashboard
        }
    }

    /// Reads the `services` query item, a comma-separated list of UUIDs.
    private static func serviceIDs(from url: URL) -> [SalonService.ID] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "services" })?.value
        else { return [] }
        return raw
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
            .map(SalonService.ID.init)
    }
}
