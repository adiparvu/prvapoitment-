import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Manage the payment methods vaulted for this client: see them, choose a
/// default, remove one — by swipe or from the row's menu, always behind a
/// confirmation — and add another through Stripe's PCI-scoped sheet.
///
/// Nothing on this screen can hold a card number — the rows carry a brand, a
/// masked suffix, and an expiry, which is everything the vault returns.
public struct PaymentMethodsView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    @State private var model = PaymentMethodsModel()

    /// Creates the screen. All dependencies come from the environment.
    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .loading:
                loadingSkeleton
            case .failed(let message):
                failureState(message)
            case .loaded:
                content
            }
        }
        .background(Color.prv.canvas)
        .navigationTitle("Payment Methods")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(for: session.currentUser, using: deps) }
        .sheet(isPresented: $model.isAddingCard) {
            AddCardSheet { method in
                model.add(method)
            }
        }
        // The pending method *is* the presentation state: there is no separate
        // flag to keep in step, and the dialog can name the card it is about
        // to remove.
        .confirmationDialog(
            "Remove this payment method?",
            item: $model.methodPendingRemoval
        ) { method in
            Button("Remove", role: .destructive) { model.confirmRemoval(of: method) }
            Button("Keep", role: .cancel) {}
        } message: { method in
            Text("\(method.displayLabel) can be added again at any time. Nothing already paid is affected.")
        }
        .prvToast($model.toast)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    PRVSectionHeader(
                        "Saved methods",
                        subtitle: model.defaultMethod.map { "\($0.displayLabel) is charged first" }
                            ?? "Tap a method to make it your default"
                    )

                    VStack(spacing: PRVSpacing.xs) {
                        ForEach(model.methods) { method in
                            methodRow(method)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        model.requestRemoval(of: method)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                    .accessibilityLabel("Remove \(method.displayLabel)")
                                }
                        }
                    }

                    vaultNote
                }
                .padding(.horizontal, PRVSpacing.md)
                .padding(.top, PRVSpacing.sm)
                .padding(.bottom, PRVSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            // These are glass cards in a plain scroll view, not List rows —
            // the container is what lets them answer a swipe.
            .swipeActionsContainer()
            .prvBottomBar { addCardButton }
        }
    }

    private func methodRow(_ method: SavedPaymentMethod) -> some View {
        HStack(spacing: PRVSpacing.xs) {
            Button {
                model.makeDefault(method)
            } label: {
                PRVListRow(title: method.displayLabel, subtitle: PaymentsFormatting.methodSubtitle(method)) {
                    PRVListRowIcon(systemImage: method.kind.symbolName)
                } trailing: {
                    if method.isDefault {
                        PRVBadge("Default", tint: Color.prv.success)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(method.displayLabel)
            .accessibilityValue(method.isDefault ? "Default method" : "Not default")
            .accessibilityHint("Double tap to make this your default")

            Menu {
                Button("Make Default") { model.makeDefault(method) }
                    .disabled(method.isDefault)
                Button("Remove", role: .destructive) { model.requestRemoval(of: method) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.prv.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(method.displayLabel)")
        }
        .prvGlassCard(radius: PRVRadius.md, padding: PRVSpacing.sm)
        .prvAnimation(PRVMotion.quick, value: method.isDefault)
    }

    private var addCardButton: some View {
        Button {
            PRVHaptics.impact()
            model.isAddingCard = true
        } label: {
            Label("Add Card", systemImage: "plus")
        }
        .buttonStyle(.prvPrimary)
        .accessibilityLabel("Add a card")
        .accessibilityHint("Opens Stripe's secure card sheet")
    }

    private var vaultNote: some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "lock.shield.fill")
                .font(.footnote)
                .foregroundStyle(Color.prv.success)
                .accessibilityHidden(true)
            Text("Cards are vaulted by Stripe. Card numbers never touch this app — PRV Beauty only ever sees the brand, the last four digits, and the expiry.")
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack {
            PRVEmptyState(
                systemImage: "creditcard",
                title: "No saved methods",
                message: "Add a card once and every future booking is one tap away. Apple Pay works without saving anything.",
                actionTitle: "Add Card"
            ) {
                model.isAddingCard = true
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSkeleton(width: 180, height: 22)
            ForEach(0..<3, id: \.self) { _ in
                PRVSkeleton(height: 64, radius: PRVRadius.md)
            }
            Spacer()
        }
        .padding(PRVSpacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your payment methods")
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "creditcard.trianglebadge.exclamationmark",
            title: "We couldn't load your methods",
            message: message,
            actionTitle: "Try Again"
        ) {
            Task { await model.load(for: session.currentUser, using: deps) }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Payment Methods — Light") {
    NavigationStack {
        PaymentMethodsView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Payment Methods — Dark") {
    NavigationStack {
        PaymentMethodsView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
