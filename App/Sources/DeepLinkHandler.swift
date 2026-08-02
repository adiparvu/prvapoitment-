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

    /// Parses a deep link, returning the route to open and the tab it belongs
    /// to. Returns `nil` for URLs this app does not handle.
    public static func route(for url: URL) -> (route: AppRoute, tab: AppTab)? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // In `prvbeauty://salon/<uuid>` the host carries the verb and the
        // first path component carries the identifier.
        guard let verb = url.host()?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let identifier = components.first.flatMap(UUID.init(uuidString:))

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
