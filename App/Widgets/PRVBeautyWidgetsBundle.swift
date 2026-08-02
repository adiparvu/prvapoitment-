import SwiftUI
import WidgetKit

/// Entry point of the PRV Beauty widget extension.
///
/// The extension is deliberately data-poor: it links only PRVFoundation,
/// PRVModels, and PRVDesignSystem, and it never performs I/O beyond reading
/// the JSON snapshot the app publishes into the `group.com.prv.beauty`
/// container. That keeps every timeline render fast, offline-safe, and free of
/// authentication concerns.
///
/// Three surfaces ship here:
/// - ``NextAppointmentWidget`` — Home Screen, small and medium.
/// - ``LoyaltyStatusWidget`` — Lock Screen ring and Home Screen tier card.
/// - ``BookingLiveActivity`` — Lock Screen banner and Dynamic Island.
@main
struct PRVBeautyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextAppointmentWidget()
        LoyaltyStatusWidget()
        BookingLiveActivity()
    }
}
