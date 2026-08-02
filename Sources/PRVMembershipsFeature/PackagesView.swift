import SwiftUI
import PRVDesignSystem
import PRVModels
import PRVNetworking

/// Packages: bundles of treatments sold together at a package price.
///
/// Each card carries its theme (bridal, seasonal, spa…), what the bundle
/// saves against booking the same treatments separately, and how long the
/// buyer has to redeem it. Buying creates an order and hands straight over to
/// checkout through the shared router — this screen never processes a payment
/// itself.
public struct PackagesView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    private let salonID: Salon.ID?

    @State private var model = PackagesModel()
    @State private var expandedPackageIDs: Set<ServicePackage.ID> = []

    /// Creates the packages screen.
    /// - Parameter salonID: Restricts packages to one salon. Pass `nil` (the
    ///   default) to browse every package on the platform.
    public init(salonID: Salon.ID? = nil) {
        self.salonID = salonID
    }

    public var body: some View {
        ScrollView {
            Group {
                switch model.phase {
                case .loading:
                    PackagesSkeleton()
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    content
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Packages")
        .navigationBarTitleDisplayMode(.large)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .prvToast($model.toast)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            PRVEmptyState(
                systemImage: "shippingbox",
                title: "No packages yet",
                message: salonID == nil
                    ? "No salon is bundling treatments right now. Memberships and gift cards are still available."
                    : "This salon doesn't sell packages yet. Their memberships might be what you're after.",
                actionTitle: "See Memberships"
            ) {
                PRVHaptics.tap()
                router.push(.memberships(salonID: salonID))
            }
            .padding(.top, PRVSpacing.xxl)
        } else {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                PRVSectionHeader(
                    "Bundles",
                    subtitle: "Booked separately, these cost more"
                )

                LazyVStack(spacing: PRVSpacing.lg) {
                    ForEach(model.packages) { package in
                        PackageCard(
                            package: package,
                            salonName: packageSalonName(for: package),
                            resolution: model.resolution(for: package),
                            isExpanded: expandedPackageIDs.contains(package.id),
                            isPurchasing: model.isPurchasing(package),
                            canPurchase: session.currentUser != nil
                        ) {
                            toggle(package)
                        } onRetryServices: {
                            retryServices(for: package)
                        } onPurchase: {
                            purchase(package)
                        }
                    }
                }
            }
        }
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "exclamationmark.icloud",
            title: "Packages unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: - Helpers

    /// Salon name for a package, shown only when the list spans salons.
    private func packageSalonName(for package: ServicePackage) -> String? {
        salonID == nil ? model.salonName(for: package) : nil
    }

    // MARK: - Actions

    private func toggle(_ package: ServicePackage) {
        if expandedPackageIDs.contains(package.id) {
            expandedPackageIDs.remove(package.id)
        } else {
            expandedPackageIDs.insert(package.id)
            // Resolution is idempotent: reopening a card never refetches.
            Task { await model.resolveServices(for: package, using: deps) }
        }
    }

    private func retryServices(for package: ServicePackage) {
        Task { await model.retryServices(for: package, using: deps) }
    }

    private func purchase(_ package: ServicePackage) {
        guard let user = session.currentUser else { return }
        Task {
            guard let order = await model.purchase(package, for: user, using: deps) else { return }
            // Payment lives in the checkout feature; we only hand over the order.
            router.present(.checkout(order.id))
        }
    }

    private func refresh() async {
        await model.load(for: session.currentUser, salonID: salonID, using: deps)
    }

    private func reload() {
        Task { await refresh() }
    }
}

// MARK: - Previews

#Preview("Packages — Client") {
    NavigationStack {
        PackagesView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
}

#Preview("Packages — Salon, Dark") {
    NavigationStack {
        PackagesView(salonID: PreviewData.salonLumiere.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
    .preferredColorScheme(.dark)
}

#Preview("Packages — Guest") {
    NavigationStack {
        PackagesView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .wallet))
}
