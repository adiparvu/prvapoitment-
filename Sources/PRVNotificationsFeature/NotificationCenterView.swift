import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The client's notification centre.
///
/// The feed is bucketed into **Today**, **This Week**, and **Earlier**, each
/// row a floating glass card with the kind's SF Symbol in a tinted squircle,
/// an unread dot, the relative time, and — when the notification carries a
/// deep link — the destination it opens. Tapping marks the notification read
/// and pushes its route onto the shared `AppRouter`; swiping marks it read in
/// place. "Mark All Read" clears the feed and the app icon badge in one move,
/// and the toolbar's settings button opens per-kind delivery switches
/// persisted with `@AppStorage`.
///
/// Every state is designed: shimmering rows while loading, a warm empty state
/// when there is nothing to show, a sign-in prompt for guests, and an inline
/// retry when the repository fails.
///
/// ```swift
/// NavigationStack { NotificationCenterView() }
/// ```
public struct NotificationCenterView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = NotificationCenterModel()

    /// Creates the notification centre. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        content
            .background(Color.prv.canvas)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .sheet(isPresented: $model.isShowingPreferences) {
                NotificationPreferencesSheet()
            }
            .prvToast($model.toast)
            .prvAnimation(PRVMotion.spring, value: model.unreadCount)
            .prvAnimation(PRVMotion.gentle, value: model.groups)
            .task(id: session.currentUser?.id) { await refresh() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.unreadCount > 0 {
            ToolbarItem(placement: .topBarLeading) {
                Button("Mark All Read") {
                    let user = session.currentUser
                    Task { await model.markAllRead(for: user, using: deps) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .accessibilityLabel("Mark all \(model.unreadCount) notifications as read")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                PRVHaptics.tap()
                model.isShowingPreferences = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
            }
            .accessibilityLabel("Notification settings")
            .accessibilityHint("Choose which notifications you receive")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            loadingList

        case .failed(let message):
            ScrollView {
                NotificationErrorCard(message: message) {
                    Task { await refresh() }
                }
                .padding(PRVSpacing.md)
                .padding(.top, PRVSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }

        case .loaded:
            if !session.isAuthenticated {
                signedOutState
            } else if model.isEmpty {
                emptyState
            } else {
                feed
            }
        }
    }

    /// Six shimmering rows — enough to fill a phone screen without implying a
    /// count the feed may not have.
    private var loadingList: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.xs) {
                ForEach(0..<6, id: \.self) { _ in
                    NotificationRowSkeleton()
                }
            }
            .padding(.horizontal, PRVSpacing.md)
            .padding(.top, PRVSpacing.xs)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
    }

    /// Bucket headers stay pinned as their rows scroll past — the same
    /// orientation the plain `List` gave them — so a notification is never
    /// read without knowing whether it landed today or a fortnight ago.
    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: PRVSpacing.xs, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.items) { notification in
                            Button {
                                open(notification)
                            } label: {
                                NotificationRow(notification: notification)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, PRVSpacing.md)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                markReadAction(for: notification)
                            }
                        }
                    } header: {
                        NotificationSectionHeader(group: group)
                    }
                }
            }
            .padding(.top, PRVSpacing.xxs)
            .padding(.bottom, PRVSpacing.xxl)
        }
        // The feed is floating glass cards in a `LazyVStack`, not list rows:
        // the scroll view itself hosts the swipe now, so swipe-to-mark-read
        // survives without a `List` — and without the row-insets, row-
        // background, separator, and minimum-height overrides it took to make
        // a `List` look like this.
        .swipeActionsContainer()
        .scrollIndicators(.hidden)
        .refreshable { await refresh() }
    }

    /// Swipe-to-clear, offered only while the notification is still unread.
    /// Built through `ContentBuilder`: it is instantiated once per row inside
    /// `ForEach`, so it type-checks on its own rather than as one expression
    /// nested two `ForEach`es deep in the feed.
    @ContentBuilder
    private func markReadAction(for notification: PRVNotification) -> some View {
        if !notification.isRead {
            Button {
                Task { await model.markRead(notification, using: deps) }
            } label: {
                Label("Mark Read", systemImage: "envelope.open.fill")
            }
            .tint(Color.prv.accent)
        }
    }

    // MARK: - Empty surfaces

    private var emptyState: some View {
        ScrollView {
            PRVEmptyState(
                systemImage: "bell.badge",
                title: "You're all caught up",
                message: "Reminders, confirmations, and waitlist openings will land here. We'll only interrupt you when it matters.",
                actionTitle: "Notification Settings"
            ) {
                model.isShowingPreferences = true
            }
            .padding(.top, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .refreshable { await refresh() }
    }

    private var signedOutState: some View {
        PRVEmptyState(
            systemImage: "lock.fill",
            title: "Sign in for notifications",
            message: "Your reminders and booking updates are tied to your account. Sign in to see them here."
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, PRVSpacing.xl)
    }

    // MARK: - Actions

    /// Marks the notification read and follows its deep link, when it has one.
    private func open(_ notification: PRVNotification) {
        PRVHaptics.tap()
        Task { await model.markRead(notification, using: deps) }
        if let route = notification.route {
            router.open(route)
        }
    }

    /// MainActor-isolated refresh entry point, callable from the `@Sendable`
    /// pull-to-refresh closure.
    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }
}

// MARK: - Previews

#Preview("Notifications — Client") {
    NavigationStack {
        NotificationCenterView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Notifications — Dark") {
    NavigationStack {
        NotificationCenterView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Notifications — Signed Out") {
    NavigationStack {
        NotificationCenterView()
    }
    .environment(UserSession())
    .environment(AppRouter())
}

#Preview("Notifications — Business") {
    NavigationStack {
        NotificationCenterView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .dashboard))
}
