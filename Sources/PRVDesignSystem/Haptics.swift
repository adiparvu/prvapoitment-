import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Centralized haptic feedback. Respects the user's system haptic settings
/// automatically via UIKit feedback generators.
@MainActor
public enum PRVHaptics {
    /// Light tap for selection and navigation.
    public static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Medium impact for meaningful actions (add to booking, apply filter).
    public static func impact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Success notification (booking confirmed, payment complete).
    public static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    public static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    public static func error() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}
