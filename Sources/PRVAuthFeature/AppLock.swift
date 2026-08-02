import SwiftUI
import Observation
import LocalAuthentication
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The biometric capability available on this device, used to pick the right
/// symbol and copy for the unlock button.
public enum BiometryKind: String, Sendable, Equatable {
    /// No biometrics available — device passcode only.
    case none
    /// Face ID.
    case faceID
    /// Touch ID.
    case touchID
    /// Optic ID (visionOS-class hardware).
    case opticID

    /// SF Symbol representing the capability.
    public var symbolName: String {
        switch self {
        case .none: "lock.fill"
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        }
    }

    /// Button title inviting the user to unlock with this capability.
    public var actionTitle: String {
        switch self {
        case .none: "Unlock"
        case .faceID: "Unlock with Face ID"
        case .touchID: "Unlock with Touch ID"
        case .opticID: "Unlock with Optic ID"
        }
    }
}

/// Observable app-lock state machine built on LocalAuthentication.
///
/// `unlock()` evaluates `.deviceOwnerAuthentication`, which automatically
/// falls back from biometrics to the device passcode — the graceful path when
/// Face ID fails or is locked out. Devices without any protection unlock
/// immediately rather than trapping the user.
@Observable
@MainActor
public final class AppLockModel {
    /// The lock lifecycle.
    public enum LockState: Equatable, Sendable {
        /// Content is hidden behind the privacy shield.
        case locked
        /// An authentication prompt is in flight.
        case evaluating
        /// The user has been verified; content may be shown.
        case unlocked
        /// The last attempt failed with a user-facing message.
        case failed(String)
    }

    /// Current position in the lock lifecycle.
    public private(set) var state: LockState
    /// Biometric capability detected on this device.
    public private(set) var biometry: BiometryKind = .none

    /// Whether the privacy shield should currently cover the app.
    public var isLocked: Bool { state != .unlocked }

    /// Creates the model, optionally starting unlocked (e.g. when the user
    /// has app lock disabled in settings).
    public init(startsLocked: Bool = true) {
        state = startsLocked ? .locked : .unlocked
        refreshBiometry()
    }

    /// Re-detects the device's biometric capability (cheap; call on foreground).
    public func refreshBiometry() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            biometry = .none
            return
        }
        biometry = switch context.biometryType {
        case .faceID: .faceID
        case .touchID: .touchID
        case .opticID: .opticID
        default: .none
        }
    }

    /// Re-engages the lock (call when the app moves to the background).
    public func lock() {
        guard state == .unlocked else { return }
        state = .locked
    }

    /// Prompts the user to authenticate. Biometric failure falls back to the
    /// device passcode automatically; cancellation simply returns to `locked`.
    public func unlock() async {
        guard state != .unlocked, state != .evaluating else { return }
        state = .evaluating

        let context = LAContext()
        context.localizedCancelTitle = "Not Now"

        var capabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &capabilityError) else {
            // No passcode is set on this device — there is nothing to
            // authenticate against, so don't trap the user behind the shield.
            PRVLog.auth.notice("Device authentication unavailable; unlocking without verification.")
            state = .unlocked
            return
        }

        do {
            let success = try await evaluate(
                context: context,
                reason: "Unlock PRV Beauty to continue."
            )
            if success {
                state = .unlocked
                PRVHaptics.success()
            } else {
                state = .locked
            }
        } catch {
            handleFailure(error)
        }
    }

    private func evaluate(context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func handleFailure(_ error: any Error) {
        if let laError = error as? LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                // A deliberate dismissal is not an error — stay quietly locked.
                state = .locked
                return
            case .biometryLockout:
                PRVHaptics.warning()
                state = .failed("Biometrics are temporarily locked. Use your device passcode to continue.")
                return
            case .passcodeNotSet:
                state = .unlocked
                return
            default:
                break
            }
        }
        PRVHaptics.error()
        PRVLog.auth.error("App lock evaluation failed: \(String(describing: error), privacy: .public)")
        state = .failed("We couldn't verify it's you. Please try again.")
    }
}

/// Full-screen lock surface: the frosted privacy shield with the brand mark
/// and a single unlock affordance. Present it over the app whenever
/// `AppLockModel.isLocked` is true.
public struct AppLockView: View {
    private let model: AppLockModel

    /// Creates the lock screen bound to the given model.
    public init(model: AppLockModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            PrivacyShieldView()

            VStack(spacing: PRVSpacing.xl) {
                ZStack {
                    Circle()
                        .fill(Color.prv.accentGradient)
                        .frame(width: 88, height: 88)
                        .prvSoftShadow()
                    Image(systemName: "sparkles")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(Color.prv.textOnAccent)
                }
                .accessibilityHidden(true)

                VStack(spacing: PRVSpacing.xs) {
                    Text("PRV Beauty")
                        .prvStyle(.title)
                    Text("Locked for your privacy")
                        .prvStyle(.subheadline)
                }

                switch model.state {
                case .evaluating:
                    ProgressView()
                        .tint(Color.prv.accent)
                        .accessibilityLabel("Verifying")
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(Color.prv.danger)
                        .prvStyle(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, PRVSpacing.xl)
                        .transition(.opacity)
                case .locked, .unlocked:
                    EmptyView()
                }

                Button {
                    Task { await model.unlock() }
                } label: {
                    Label(model.biometry.actionTitle, systemImage: model.biometry.symbolName)
                }
                .buttonStyle(.prvPrimary)
                .disabled(model.state == .evaluating)
                .frame(maxWidth: 320)
                .padding(.horizontal, PRVSpacing.xl)
                .accessibilityLabel(model.biometry.actionTitle)
            }
            .padding(PRVSpacing.xl)
        }
        .prvAnimation(PRVMotion.spring, value: model.state)
        .task {
            // Prompt immediately when biometrics exist — one glance and in.
            if model.biometry != .none, model.isLocked {
                await model.unlock()
            }
        }
    }
}

/// A frosted glass veil that hides sensitive content without revealing any UI.
/// Use it for app-switcher snapshots and beneath the app-lock screen.
public struct PrivacyShieldView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Creates the shield. It renders edge to edge and ignores safe areas.
    public init() {}

    public var body: some View {
        ZStack {
            if reduceTransparency {
                Color.prv.canvas
            } else {
                Rectangle().fill(.thickMaterial)
            }

            Circle()
                .fill(Color.prv.accentGradient)
                .frame(width: 320, height: 320)
                .opacity(0.16)
                .blur(radius: 70)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("App lock") {
    AppLockView(model: AppLockModel())
        .environment(UserSession.previewClient)
}

#Preview("App lock — dark") {
    AppLockView(model: AppLockModel())
        .environment(UserSession.previewClient)
        .preferredColorScheme(.dark)
}

#Preview("Privacy shield") {
    PrivacyShieldView()
}
