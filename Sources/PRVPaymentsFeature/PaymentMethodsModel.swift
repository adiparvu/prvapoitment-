import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model backing ``PaymentMethodsView``.
///
/// Loads the client's vaulted methods and owns the management actions:
/// choosing a default, removing one, and adding a card through the PCI-scoped
/// tokenization handoff.
///
/// - Important: `PaymentRepository` currently exposes `savedMethods(userID:)`
///   only — it has no update, delete, or insert endpoint. Until it gains them,
///   the actions here update the loaded list so the UI is immediate and
///   truthful about the current session, and a reload restores whatever the
///   backend holds. The repository additions belong in `PRVNetworking`, which
///   this module does not own.
@Observable
@MainActor
final class PaymentMethodsModel {
    /// Lifecycle of the initial load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var methods: [SavedPaymentMethod] = []

    /// Whether the add-card sheet is presented.
    var isAddingCard = false
    /// The method the client asked to remove. Setting it presents the
    /// confirmation; SwiftUI clears it again when the dialog goes away.
    var methodPendingRemoval: SavedPaymentMethod?
    /// Transient feedback.
    var toast: PRVToast?

    /// Creates the model.
    init() {}

    // MARK: - Loading

    /// Loads the client's saved methods. Safe to call again to retry.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            phase = .failed("Sign in to manage your payment methods.")
            return
        }
        phase = .loading
        do {
            methods = try await deps.payments.savedMethods(userID: user.id).sorted { lhs, rhs in
                lhs.isDefault && !rhs.isDefault
            }
            phase = .loaded
        } catch {
            PRVLog.payments.error("Payment methods load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(PaymentsFormatting.friendlyError(error, subject: "Your payment methods"))
        }
    }

    /// Whether the client has nothing vaulted yet.
    var isEmpty: Bool { phase == .loaded && methods.isEmpty }

    /// The current default method, when one is set.
    var defaultMethod: SavedPaymentMethod? { methods.first(where: \.isDefault) }

    // MARK: - Management

    /// Makes one method the default, clearing the flag on every other.
    func makeDefault(_ method: SavedPaymentMethod) {
        guard !method.isDefault else { return }
        methods = methods.map { entry in
            var copy = entry
            copy.isDefault = entry.id == method.id
            return copy
        }
        methods.sort { lhs, rhs in lhs.isDefault && !rhs.isDefault }
        PRVHaptics.success()
        toast = .success("\(method.displayLabel) is now your default.")
    }

    /// Asks for confirmation before removing a method.
    func requestRemoval(of method: SavedPaymentMethod) {
        methodPendingRemoval = method
    }

    /// Removes the confirmed method, promoting a new default when the removed
    /// one held that role.
    ///
    /// - Parameter method: The method the confirmation dialog was presenting.
    ///   It is passed in rather than re-read from ``methodPendingRemoval``,
    ///   which the item-bound dialog has already cleared by the time the
    ///   destructive button fires.
    func confirmRemoval(of method: SavedPaymentMethod) {
        methodPendingRemoval = nil
        methods.removeAll { $0.id == method.id }
        if method.isDefault, !methods.isEmpty {
            methods[0].isDefault = true
        }
        PRVHaptics.impact()
        toast = .info("\(method.displayLabel) removed.")
    }

    /// Adds a freshly vaulted method returned by the tokenizer.
    func add(_ method: SavedPaymentMethod) {
        if method.isDefault {
            methods = methods.map { entry in
                var copy = entry
                copy.isDefault = false
                return copy
            }
        }
        methods.insert(method, at: method.isDefault ? 0 : methods.count)
        isAddingCard = false
        PRVHaptics.success()
        toast = .success("\(method.displayLabel) added.")
    }
}
