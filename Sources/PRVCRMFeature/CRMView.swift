import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The salon's client book.
///
/// A glass search field queries the CRM repository directly (debounced by
/// rekeying the load task), three stat tiles frame the book at a glance, and a
/// sort menu reorders it by last visit, name, spend, or visit count. Tapping a
/// client pushes the shared `.clientRecord` route; the "New client" sheet
/// writes straight through `upsertClient`.
public struct CRMView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = CRMModel()
    @State private var isAddingClient = false

    private var statColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 148), spacing: PRVSpacing.sm)]
    }

    /// Creates the client book. All dependencies come from the environment;
    /// the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                PRVSearchField(text: $model.searchText, prompt: "Search clients")

                switch model.phase {
                case .loading:
                    ClientListSkeleton()
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
        .navigationTitle("Clients")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    PRVHaptics.tap()
                    isAddingClient = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .accessibilityLabel("New client")
            }
        }
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .prvAnimation(PRVMotion.spring, value: model.sort)
        .refreshable { await refresh() }
        .task(id: loadIdentity) {
            // Debounce keystrokes: a new identity cancels the pending task.
            if model.isSearching, model.hasLoadedOnce {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
            }
            await refresh()
        }
        .sheet(isPresented: $isAddingClient) {
            NewClientSheet(salonID: salonID) { record in
                await create(record)
            }
        }
        .prvToast($model.toast)
    }

    // MARK: - Toolbar

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortBinding) {
                ForEach(ClientSort.allCases) { option in
                    Label(option.title, systemImage: option.symbolName)
                        .tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("Sort clients, currently \(model.sort.title)")
    }

    private var sortBinding: Binding<ClientSort> {
        Binding(
            get: { model.sort },
            set: { newValue in
                PRVHaptics.tap()
                model.sort = newValue
            }
        )
    }

    // MARK: - States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "person.2.slash",
            title: "Client book unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    @ViewBuilder
    private var content: some View {
        if model.sortedClients.isEmpty {
            emptyState
        } else {
            statsRow
            clientList
        }
    }

    private var emptyState: some View {
        Group {
            if model.isSearching {
                PRVEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No client matches “\(model.searchText)”. Try a different spelling, or add them as a new client.",
                    actionTitle: "New Client"
                ) {
                    PRVHaptics.tap()
                    isAddingClient = true
                }
            } else {
                PRVEmptyState(
                    systemImage: "person.2",
                    title: "No clients yet",
                    message: "Every booking creates a client record. You can also add walk-ins by hand.",
                    actionTitle: "New Client"
                ) {
                    PRVHaptics.tap()
                    isAddingClient = true
                }
            }
        }
        .padding(.top, PRVSpacing.xl)
    }

    // MARK: - Content

    private var statsRow: some View {
        LazyVGrid(columns: statColumns, spacing: PRVSpacing.sm) {
            PRVStatTile(label: "Clients", value: "\(model.clients.count)")
                .accessibilityLabel("\(model.clients.count) clients in the book")

            PRVStatTile(label: "New this month", value: "\(model.newThisMonth)")
                .accessibilityLabel("\(model.newThisMonth) clients added in the last 30 days")

            PRVStatTile(label: "Lifetime spend", value: model.totalSpend.formatted)
                .accessibilityLabel("Lifetime spend across the book, \(model.totalSpend.formatted)")

            PRVStatTile(label: "Lapsed 90d+", value: "\(model.lapsedCount)")
                .accessibilityLabel("\(model.lapsedCount) clients have not visited in over 90 days")
        }
    }

    private var clientList: some View {
        LazyVStack(spacing: PRVSpacing.xs) {
            ForEach(model.sortedClients) { client in
                Button {
                    PRVHaptics.tap()
                    router.push(.clientRecord(client.id))
                } label: {
                    ClientRow(client: client)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    /// The salon in scope, falling back to the flagship fixture so previews and
    /// demo mode always have a book to show.
    private var salonID: Salon.ID {
        session.activeSalonID ?? PreviewData.salonLumiere.id
    }

    private var loadIdentity: String {
        "\(salonID.description)-\(model.searchText)"
    }

    private func refresh() async {
        await model.load(salonID: salonID, using: deps)
    }

    private func reload() {
        let salonID = salonID
        let deps = deps
        Task { await model.load(salonID: salonID, using: deps) }
    }

    private func create(_ record: ClientRecord) async -> Bool {
        await model.upsert(record, using: deps)
    }
}

// MARK: - Row

/// One client in the book: avatar, name, last visit, tier badge, and spend.
struct ClientRow: View {
    let client: ClientRecord

    private var tier: ClientTier { ClientTier.tier(for: client) }

    var body: some View {
        PRVListRow(
            title: client.fullName,
            subtitle: subtitle
        ) {
            PRVAvatar(name: client.fullName, imageURL: client.avatarURL, size: .medium)
        } trailing: {
            VStack(alignment: .trailing, spacing: PRVSpacing.xxs) {
                PRVBadge(tier.title, tint: tier.tint)
                Text(client.totalSpend.formatted)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary)
                    .monospacedDigit()
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the client record")
    }

    private var subtitle: String {
        "\(CRMFormat.lastVisit(client.lastVisitAt)) · \(client.totalVisits) visits"
    }

    private var accessibilityLabel: String {
        "\(client.fullName), \(tier.title). \(CRMFormat.lastVisit(client.lastVisitAt)), \(client.totalVisits) visits, \(client.totalSpend.formatted) lifetime."
    }
}

// MARK: - Previews

#Preview("Clients — Owner") {
    NavigationStack {
        CRMView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .clients))
}

#Preview("Clients — Dark") {
    NavigationStack {
        CRMView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .clients))
    .preferredColorScheme(.dark)
}
