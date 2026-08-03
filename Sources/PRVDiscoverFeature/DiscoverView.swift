import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// AI-forward discovery: a natural-language search field with a debounced
/// (300 ms) structured search underneath, an inline "Ask AI" flow that
/// renders Beauty Assistant recommendations as tappable cards, quick filter
/// chips plus a full filter sheet driving `SalonSearchQuery`, and — in the
/// navigation bar — a sort menu and the switch to a MapKit map with branded
/// salon annotations.
///
/// Data access goes exclusively through `@Environment(\.prvDependencies)`;
/// cross-feature navigation through the shared `AppRouter`.
public struct DiscoverView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = DiscoverModel()

    /// Creates the discovery screen. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(spacing: PRVSpacing.sm) {
                PRVSearchField(
                    text: $model.searchText,
                    prompt: "Try “I need bridal hair and makeup in June”"
                ) {
                    model.searchNow(using: deps)
                }
                .padding(.horizontal, PRVSpacing.lg)

                assistantRow
                    .padding(.horizontal, PRVSpacing.lg)

                filterBar

                resultsHeader
                    .padding(.horizontal, PRVSpacing.lg)
            }
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.sm)

            content
        }
        .background(Color.prv.canvas)
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        // The header stack above the results is fixed, so the bar is the only
        // chrome that can step aside: minimizing it on scroll-down gives the
        // image-led result cards the screen while search and filters stay put.
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
        .prvAnimation(PRVMotion.spring, value: model.assistantPhase)
        .prvAnimation(PRVMotion.gentle, value: model.isMapMode)
        .onChange(of: model.searchText) { _, _ in
            model.scheduleSearch(using: deps)
        }
        .task { await model.loadInitial(using: deps) }
        .sheet(isPresented: $model.isShowingFilters) {
            DiscoverFilterSheet(query: model.query) { applied in
                model.apply(applied, using: deps)
            }
        }
    }

    // MARK: - Toolbar

    /// Sort and the list/map switch belong to the whole result set rather than
    /// to any one row, so they sit in the navigation bar instead of spending a
    /// line of fixed chrome above the results.
    ///
    /// The mode switch is pinned because map mode hides the list — and every
    /// affordance on it — leaving this the only way back. Sort takes high
    /// visibility priority since its menu is the only place to change ordering,
    /// while filters keep their chip in the filter bar; on a narrow width, or
    /// beside the shell's pinned guest "Sign In", those two survive first.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            sortMenu
        }
        .visibilityPriority(.high)

        ToolbarItem(placement: .topBarPinnedTrailing) {
            mapToggle
        }
    }

    // MARK: - Header

    /// The inline assistant surface under the search field: the "Ask AI"
    /// affordance when the query reads like a sentence, a thinking shimmer,
    /// or a retryable error. The answer itself renders in the results list.
    @ViewBuilder
    private var assistantRow: some View {
        if let user = session.currentUser {
            switch model.assistantPhase {
            case .idle:
                if model.looksLikeSentence {
                    AskAssistantRow(queryText: model.searchText.trimmed) {
                        model.askAssistant(userID: user.id, using: deps)
                    }
                }
            case .thinking:
                AssistantThinkingRow()
            case .failed(let message):
                AssistantErrorRow(message: message) {
                    model.askAssistant(userID: user.id, using: deps)
                }
            case .answered:
                EmptyView()
            }
        }
    }

    /// Quick filter chips: the sheet entry point, verified, a rating floor,
    /// availability windows, and every business category — each writing
    /// straight into the `SalonSearchQuery`.
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PRVSpacing.xs) {
                PRVChip(
                    filtersChipTitle,
                    systemImage: "slider.horizontal.3",
                    isSelected: model.activeFilterCount > 0
                ) {
                    model.isShowingFilters = true
                }

                PRVChip(
                    "Verified",
                    systemImage: "checkmark.seal.fill",
                    isSelected: model.query.verifiedOnly
                ) {
                    model.toggleVerified(using: deps)
                }

                PRVChip(
                    "4.5+",
                    systemImage: "star.fill",
                    isSelected: model.query.minRating == 4.5
                ) {
                    model.toggleMinRating(4.5, using: deps)
                }

                ForEach(SalonSearchQuery.AvailabilityWindow.quickChoices, id: \.self) { window in
                    PRVChip(
                        window.displayName,
                        systemImage: window.symbolName,
                        isSelected: model.query.availability == window
                    ) {
                        model.setAvailability(window, using: deps)
                    }
                }

                ForEach(BusinessCategory.allCases, id: \.self) { category in
                    PRVChip(
                        category.displayName,
                        systemImage: category.symbolName,
                        isSelected: model.query.categories.contains(category)
                    ) {
                        model.toggleCategory(category, using: deps)
                    }
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private var filtersChipTitle: String {
        model.activeFilterCount > 0 ? "Filters · \(model.activeFilterCount)" : "Filters"
    }

    /// Result count and the in-flight indicator; sort and the map switch live
    /// in the navigation bar.
    private var resultsHeader: some View {
        HStack(spacing: PRVSpacing.sm) {
            if let results = model.results {
                Text("^[\(results.count) place](inflect: true)")
                    .prvStyle(.headline)
                    .accessibilityLabel("\(results.count) results")
            }
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }

            Spacer(minLength: PRVSpacing.xs)
        }
    }

    /// Bar-hosted sort control: the label stays a plain `Label` because the
    /// bar now supplies the Liquid Glass the old hand-rolled pill drew itself.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(
                get: { model.query.sort },
                set: { model.setSort($0, using: deps) }
            )) {
                ForEach(SalonSearchQuery.Sort.allCases, id: \.self) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
        } label: {
            Label(model.query.sort.displayName, systemImage: "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityLabel("Sort by \(model.query.sort.displayName)")
    }

    private var mapToggle: some View {
        Button {
            PRVHaptics.tap()
            model.isMapMode.toggle()
        } label: {
            Image(systemName: model.isMapMode ? "list.bullet" : "map.fill")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityLabel(model.isMapMode ? "Show results as list" : "Show results on map")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isMapMode {
            mapContent
        } else {
            listContent
        }
    }

    private var mapContent: some View {
        SalonMapView(salons: model.results ?? []) { salon in
            open(salon)
        }
        .overlay {
            if model.isSearching && model.results == nil {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PRVSpacing.md) {
                if case .answered(let resolved) = model.assistantPhase {
                    AssistantResultsCard(
                        resolved: resolved,
                        onOpenService: { service in
                            if let salonID = service.salonID {
                                router.push(.service(service.id, salonID: salonID))
                            }
                        },
                        onOpenSalon: { open($0) },
                        onOpenProfessional: { router.push(.professional($0.id)) },
                        onDismiss: { model.dismissAssistant() }
                    )
                }

                resultsList
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.xs)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var resultsList: some View {
        if let results = model.results {
            if results.isEmpty {
                PRVEmptyState(
                    systemImage: "sparkle.magnifyingglass",
                    title: "No matches",
                    message: "Try a different treatment, widen your filters, or ask the assistant for ideas.",
                    actionTitle: model.activeFilterCount > 0 ? "Clear Filters" : nil
                ) {
                    model.clearFilters(using: deps)
                }
                .padding(.top, PRVSpacing.xl)
            } else {
                if let message = model.errorMessage {
                    staleResultsBanner(message)
                }
                ForEach(results) { salon in
                    SalonResultCard(
                        salon: salon,
                        distanceText: model.distanceText(to: salon),
                        onOpen: { open(salon) },
                        onBook: { open(salon) }
                    )
                }
            }
        } else if let message = model.errorMessage {
            PRVEmptyState(
                systemImage: "wifi.exclamationmark",
                title: "Search unavailable",
                message: message,
                actionTitle: "Try Again"
            ) {
                model.searchNow(using: deps)
            }
            .padding(.top, PRVSpacing.xl)
        } else {
            ForEach(0..<2, id: \.self) { _ in
                SalonCardSkeleton()
            }
        }
    }

    /// Quiet banner shown when a refresh failed but older results remain.
    private func staleResultsBanner(_ message: String) -> some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)
            Text(message)
                .prvStyle(.caption)
            Spacer(minLength: PRVSpacing.xs)
            Button {
                PRVHaptics.tap()
                model.searchNow(using: deps)
            } label: {
                Text("Retry")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
            }
            .accessibilityLabel("Retry search")
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.warning.opacity(0.08), in: PRVRadius.shape(PRVRadius.md))
    }

    // MARK: - Actions

    /// Records the view for "Recently Viewed" and pushes the salon profile.
    private func open(_ salon: Salon) {
        let salons = deps.salons
        Task { await salons.markViewed(salonID: salon.id) }
        router.push(.salon(salon.id))
    }
}

// MARK: - Previews

#Preview("Discover") {
    NavigationStack {
        DiscoverView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Discover — Dark") {
    NavigationStack {
        DiscoverView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
