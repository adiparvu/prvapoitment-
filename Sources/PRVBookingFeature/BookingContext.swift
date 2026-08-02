import Foundation
import PRVModels

/// The entry payload for ``BookingFlowView``: which salon is being booked and
/// which services the client arrived with (from a salon profile, a search
/// result, or an assistant recommendation).
///
/// The flow treats `serviceIDs` as a pre-selection, not a lock: clients can
/// add or remove services in the first step.
///
/// ```swift
/// BookingFlowView(
///     context: BookingContext(salonID: salon.id, serviceIDs: [service.id])
/// )
/// ```
public struct BookingContext: Sendable, Hashable {
    /// The salon the appointment will be booked with.
    public var salonID: Salon.ID
    /// Services pre-selected when the flow opens. May be empty.
    public var serviceIDs: [SalonService.ID]

    /// Creates a booking context.
    /// - Parameters:
    ///   - salonID: The salon being booked.
    ///   - serviceIDs: Services to pre-select. Defaults to none.
    public init(salonID: Salon.ID, serviceIDs: [SalonService.ID] = []) {
        self.salonID = salonID
        self.serviceIDs = serviceIDs
    }
}

/// The stages of the booking flow, in order. The confirmation stage sits
/// outside the progress indicator — it is the destination, not a step.
enum BookingStep: Int, CaseIterable, Hashable, Sendable, Comparable {
    case services
    case professional
    case time
    case review
    case confirmation

    /// Steps represented in the progress indicator.
    static var progressSteps: [BookingStep] { [.services, .professional, .time, .review] }

    /// Screen title for the step.
    var title: String {
        switch self {
        case .services: "Choose Services"
        case .professional: "Choose Your Artist"
        case .time: "Pick a Time"
        case .review: "Review & Pay"
        case .confirmation: "You're Booked"
        }
    }

    /// Compact label used by the progress indicator.
    var shortTitle: String {
        switch self {
        case .services: "Services"
        case .professional: "Artist"
        case .time: "Time"
        case .review: "Review"
        case .confirmation: "Done"
        }
    }

    /// SF Symbol representing the step.
    var symbolName: String {
        switch self {
        case .services: "list.bullet.rectangle"
        case .professional: "person.crop.circle"
        case .time: "clock"
        case .review: "checkmark.seal"
        case .confirmation: "sparkles"
        }
    }

    /// The step before this one, or `nil` at the start of the flow.
    var previous: BookingStep? {
        BookingStep(rawValue: rawValue - 1)
    }

    /// The step after this one, or `nil` at the end of the flow.
    var next: BookingStep? {
        BookingStep(rawValue: rawValue + 1)
    }

    static func < (lhs: BookingStep, rhs: BookingStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
