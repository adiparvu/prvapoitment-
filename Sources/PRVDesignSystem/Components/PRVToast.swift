import SwiftUI

/// A transient in-app notification shown as a floating glass capsule at the
/// top of the screen. Present one by setting a bound optional:
///
/// ```swift
/// @State private var toast: PRVToast?
///
/// var body: some View {
///     content
///         .prvToast($toast)
/// }
///
/// // Later:
/// toast = .success("Booking confirmed")
/// ```
public struct PRVToast: Equatable, Sendable {
    /// Visual + haptic style of a toast.
    public enum Style: Equatable, Sendable {
        case success
        case warning
        case error
        case info

        /// Default SF Symbol for the style.
        var defaultSymbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .info: "info.circle.fill"
            }
        }

        /// Icon tint for the style.
        var tint: Color {
            switch self {
            case .success: Color.prv.success
            case .warning: Color.prv.warning
            case .error: Color.prv.danger
            case .info: Color.prv.accent
            }
        }
    }

    /// The toast's visual style (drives icon, tint, and haptic).
    public var style: Style
    /// The message shown to the user. Keep it to one short sentence.
    public var message: String
    /// SF Symbol shown before the message; defaults per style.
    public var systemImage: String

    /// Creates a toast.
    /// - Parameters:
    ///   - style: Visual style.
    ///   - message: Short, human message.
    ///   - systemImage: Optional symbol override; defaults per style.
    public init(style: Style, message: String, systemImage: String? = nil) {
        self.style = style
        self.message = message
        self.systemImage = systemImage ?? style.defaultSymbol
    }

    /// A green success toast.
    public static func success(_ message: String) -> PRVToast {
        PRVToast(style: .success, message: message)
    }

    /// An amber warning toast.
    public static func warning(_ message: String) -> PRVToast {
        PRVToast(style: .warning, message: message)
    }

    /// A red error toast.
    public static func error(_ message: String) -> PRVToast {
        PRVToast(style: .error, message: message)
    }

    /// A neutral informational toast.
    public static func info(_ message: String) -> PRVToast {
        PRVToast(style: .info, message: message)
    }
}

extension View {
    /// Presents a ``PRVToast`` whenever the binding becomes non-`nil`, then
    /// auto-dismisses it after `duration`. Presenting fires the matching
    /// haptic; the slide transition respects Reduce Motion.
    public func prvToast(
        _ toast: Binding<PRVToast?>,
        duration: Duration = .seconds(2.6)
    ) -> some View {
        modifier(PRVToastModifier(toast: toast, duration: duration))
    }
}

/// Hosts the toast overlay, its transition, haptics, and auto-dismissal.
private struct PRVToastModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var toast: PRVToast?
    let duration: Duration

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    PRVToastView(toast: toast) {
                        self.toast = nil
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .task(id: toast) {
                        switch toast.style {
                        case .success: PRVHaptics.success()
                        case .warning: PRVHaptics.warning()
                        case .error: PRVHaptics.error()
                        case .info: PRVHaptics.tap()
                        }
                        try? await Task.sleep(for: duration)
                        guard !Task.isCancelled else { return }
                        self.toast = nil
                    }
                }
            }
            .prvAnimation(PRVMotion.spring, value: toast)
    }
}

/// The floating glass capsule itself. Tapping dismisses early.
private struct PRVToastView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let toast: PRVToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: toast.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(toast.style.tint)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.prv.textPrimary)
                .lineLimit(2)
        }
        .padding(.vertical, PRVSpacing.sm)
        .padding(.horizontal, PRVSpacing.md)
        .background {
            if reduceTransparency {
                Capsule().fill(Color.prv.surfaceElevated)
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
        .prvSoftShadow()
        .padding(.horizontal, PRVSpacing.lg)
        .padding(.top, PRVSpacing.xs)
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.message)
        .accessibilityHint("Double tap to dismiss")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Toast — Light") {
    @Previewable @State var toast: PRVToast? = .success("Booking confirmed")
    VStack(spacing: PRVSpacing.sm) {
        Spacer()
        Button("Success") { toast = .success("Booking confirmed") }
            .buttonStyle(.prvGlass)
        Button("Error") { toast = .error("Payment failed — try another card") }
            .buttonStyle(.prvGlass)
        Button("Info") { toast = .info("Amélie is running 5 min late") }
            .buttonStyle(.prvGlass)
        Spacer()
    }
    .frame(maxWidth: .infinity)
    .background(Color.prv.canvas)
    .prvToast($toast)
}

#Preview("Toast — Dark") {
    @Previewable @State var toast: PRVToast? = .warning("Only 2 slots left today")
    Color.prv.canvas
        .ignoresSafeArea()
        .prvToast($toast)
        .preferredColorScheme(.dark)
}
