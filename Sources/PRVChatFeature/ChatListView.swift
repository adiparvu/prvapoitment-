import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The client's message centre: the Beauty Assistant pinned at the top with
/// its signature sparkle treatment, then every salon and professional thread
/// as a floating glass row carrying an avatar, the latest preview, relative
/// recency, an unread badge, and an end-to-end-encryption glyph.
///
/// Rows swipe to mark as read, the search field filters titles and previews
/// live, and each state — loading, empty, no matches, failure — has its own
/// considered surface.
///
/// ```swift
/// NavigationStack { ChatListView() }
/// ```
public struct ChatListView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = ChatListModel()

    /// Creates the message centre. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: PRVSpacing.sm) {
            PRVSearchField(text: $model.searchText, prompt: "Search messages")
                .padding(.horizontal, PRVSpacing.md)
                .padding(.top, PRVSpacing.xs)

            content
        }
        .background(Color.prv.canvas)
        .navigationTitle("Messages")
        .toolbar { toolbarContent }
        .task(id: session.currentUser?.id) { await refresh() }
        .prvToast($model.toast)
        .prvAnimation(PRVMotion.spring, value: model.searchText)
        .prvAnimation(PRVMotion.spring, value: model.totalUnreadCount)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                PRVHaptics.impact()
                router.push(.beautyAssistant)
            } label: {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.prv.accentGradient)
            }
            .accessibilityLabel("Open Beauty Assistant")
        }

        if model.totalUnreadCount > 0 {
            ToolbarItem(placement: .topBarLeading) {
                Button("Mark All Read") {
                    Task { await model.markAllRead(using: deps) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .accessibilityLabel("Mark all conversations as read")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView {
                VStack(spacing: PRVSpacing.sm) {
                    ForEach(0..<6, id: \.self) { _ in
                        ConversationRowSkeleton()
                    }
                }
                .padding(.horizontal, PRVSpacing.md)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)

        case .failed(let message):
            ScrollView {
                ChatErrorCard(message: message) {
                    Task { await refresh() }
                }
                .padding(PRVSpacing.md)
            }
            .refreshable { await refresh() }

        case .loaded:
            if !session.isAuthenticated {
                signedOutState
            } else if model.hasNoConversations && model.searchText.trimmed.isEmpty {
                emptyState
            } else if model.hasNoMatches {
                noMatchesState
            } else {
                conversationList
            }
        }
    }

    private var conversationList: some View {
        List {
            if model.showsAssistant, let assistant = model.assistantConversation {
                Section {
                    Button {
                        PRVHaptics.impact()
                        router.push(.beautyAssistant)
                    } label: {
                        AssistantConversationRow(conversation: assistant)
                    }
                    .buttonStyle(.plain)
                    .modifier(ChatListRowChrome())
                }
            }

            Section {
                ForEach(model.filteredConversations) { conversation in
                    Button {
                        PRVHaptics.tap()
                        router.push(.conversation(conversation.id))
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(.plain)
                    .modifier(ChatListRowChrome())
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if conversation.unreadCount > 0 {
                            Button {
                                Task { await model.markRead(conversation, using: deps) }
                            } label: {
                                Label("Mark Read", systemImage: "envelope.open.fill")
                            }
                            .tint(Color.prv.accent)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .refreshable { await refresh() }
    }

    // MARK: - Empty surfaces

    private var emptyState: some View {
        ScrollView {
            PRVEmptyState(
                systemImage: "bubble.left.and.bubble.right",
                title: "No messages yet",
                message: "Message a salon before your visit, or ask the Beauty Assistant to plan your next look.",
                actionTitle: "Ask the Assistant"
            ) {
                router.push(.beautyAssistant)
            }
            .padding(.top, PRVSpacing.xxl)
        }
        .refreshable { await refresh() }
    }

    private var noMatchesState: some View {
        PRVEmptyState(
            systemImage: "magnifyingglass",
            title: "No matches",
            message: "No conversation mentions “\(model.searchText.trimmed)”. Try a salon or treatment name."
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, PRVSpacing.xl)
    }

    private var signedOutState: some View {
        PRVEmptyState(
            systemImage: "lock.fill",
            title: "Sign in to message",
            message: "Conversations with your salon are end-to-end encrypted. Sign in to pick up where you left off."
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, PRVSpacing.xl)
    }

    // MARK: - Actions

    /// MainActor-isolated refresh, callable from `@Sendable` refresh closures.
    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }
}

// MARK: - Row chrome

/// Strips the system list chrome so the glass rows float on the canvas.
private struct ChatListRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: PRVSpacing.xxs,
                leading: PRVSpacing.md,
                bottom: PRVSpacing.xxs,
                trailing: PRVSpacing.md
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Rows

/// One salon, professional, or support thread.
struct ConversationRow: View {
    let conversation: Conversation

    private var isUnread: Bool { conversation.unreadCount > 0 }

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            PRVAvatar(
                name: conversation.title,
                imageURL: conversation.avatarURL,
                size: .medium
            )
            .overlay(alignment: .bottomTrailing) {
                if isUnread {
                    Circle()
                        .fill(Color.prv.accentGradient)
                        .frame(width: 12, height: 12)
                        .overlay { Circle().strokeBorder(Color.prv.canvas, lineWidth: 2) }
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: PRVSpacing.xxs) {
                    Text(conversation.title)
                        .font(.body.weight(isUnread ? .semibold : .medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)

                    if conversation.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary.opacity(0.7))
                            .accessibilityHidden(true)
                    }
                }

                Text(conversation.lastMessagePreview ?? conversation.kindDescription)
                    .font(.subheadline)
                    .foregroundStyle(isUnread ? Color.prv.textPrimary : Color.prv.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PRVSpacing.xs)

            VStack(alignment: .trailing, spacing: PRVSpacing.xxs) {
                Text(ChatFormat.recency(conversation.lastMessageAt))
                    .prvStyle(.caption)
                    .monospacedDigit()
                PRVBadge(count: conversation.unreadCount)
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.sm)
        .contentShape(PRVRadius.shape(PRVRadius.lg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the conversation")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [conversation.title]
        if conversation.isEncrypted { parts.append("end-to-end encrypted") }
        if let preview = conversation.lastMessagePreview { parts.append(preview) }
        if let date = conversation.lastMessageAt { parts.append(ChatFormat.spokenTimestamp(date)) }
        if isUnread {
            parts.append("\(conversation.unreadCount) unread message\(conversation.unreadCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}

/// The pinned Beauty Assistant thread, styled apart from human threads with
/// the brand gradient, a sparkle mark, and a soft gradient border.
struct AssistantConversationRow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let conversation: Conversation

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            ZStack {
                Circle().fill(Color.prv.accentGradient)
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.prv.textOnAccent)
            }
            .frame(width: 44, height: 44)
            .prvSoftShadow()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: PRVSpacing.xxs) {
                    Text("Beauty Assistant")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.prv.accentGradient)
                        .lineLimit(1)
                    PRVBadge("AI", tint: Color.prv.gold)
                }

                Text(conversation.lastMessagePreview ?? "Tell me your goal and I'll plan the whole look.")
                    .font(.subheadline)
                    .foregroundStyle(Color.prv.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PRVSpacing.xs)

            VStack(alignment: .trailing, spacing: PRVSpacing.xxs) {
                Text(ChatFormat.recency(conversation.lastMessageAt))
                    .prvStyle(.caption)
                    .monospacedDigit()
                PRVBadge(count: conversation.unreadCount)
            }
        }
        .padding(PRVSpacing.sm)
        .background {
            if reduceTransparency {
                PRVRadius.shape(PRVRadius.lg).fill(Color.prv.surface)
            } else {
                PRVRadius.shape(PRVRadius.lg).fill(.ultraThinMaterial)
            }
        }
        .background {
            PRVRadius.shape(PRVRadius.lg)
                .fill(Color.prv.accent.opacity(0.10))
        }
        .clipShape(PRVRadius.shape(PRVRadius.lg))
        .overlay {
            PRVRadius.shape(PRVRadius.lg)
                .strokeBorder(Color.prv.accentGradient.opacity(0.45), lineWidth: 1)
        }
        .prvSoftShadow()
        .contentShape(PRVRadius.shape(PRVRadius.lg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Beauty Assistant, your AI beauty concierge")
        .accessibilityHint("Opens the Beauty Assistant")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Loading + failure surfaces

/// Shimmering stand-in for a conversation row.
struct ConversationRowSkeleton: View {
    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            PRVSkeleton(width: 44, height: 44, radius: 22)
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                PRVSkeleton(width: 140, height: 15)
                PRVSkeleton(height: 12)
            }
            Spacer(minLength: PRVSpacing.xs)
            PRVSkeleton(width: 34, height: 11)
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.sm)
        .accessibilityHidden(true)
    }
}

/// Inline failure surface with a retry affordance, used across the module.
struct ChatErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        PRVGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md) {
            VStack(spacing: PRVSpacing.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(Color.prv.warning)
                    .accessibilityHidden(true)

                Text(message)
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    PRVHaptics.tap()
                    retry()
                }
                .buttonStyle(.prvGlass)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Previews

#Preview("Chat List — Client") {
    NavigationStack {
        ChatListView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .chat))
}

#Preview("Chat List — Dark") {
    NavigationStack {
        ChatListView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .chat))
    .preferredColorScheme(.dark)
}

#Preview("Chat List — Signed Out") {
    NavigationStack {
        ChatListView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .chat))
}
