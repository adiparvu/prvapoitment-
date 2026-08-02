import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model backing ``ChatListView``.
///
/// Loads the client's conversations together with their dedicated Beauty
/// Assistant thread — the assistant is created on first use, so it is
/// requested explicitly rather than hoped for in the list — and owns the
/// search filter plus optimistic mark-as-read.
@Observable
@MainActor
final class ChatListModel {
    /// Lifecycle of the conversation list.
    private(set) var phase: ChatPhase = .loading
    /// Every conversation the user participates in, newest activity first.
    private(set) var conversations: [Conversation] = []

    /// Live search text filtering titles and message previews.
    var searchText = ""
    /// Transient feedback for background failures (mark-read, refresh).
    var toast: PRVToast?

    /// Creates an empty model; call ``load(for:using:)`` to populate it.
    init() {}

    // MARK: - Derived state

    /// The pinned Beauty Assistant thread, always shown first.
    var assistantConversation: Conversation? {
        conversations.first { $0.kind == .assistant }
    }

    /// Human conversations matching the current search text.
    var filteredConversations: [Conversation] {
        let people = conversations.filter { $0.kind != .assistant }
        let query = searchText.trimmed
        guard !query.isEmpty else { return people }
        return people.filter { $0.matches(query) }
    }

    /// Whether the assistant row survives the current search text.
    var showsAssistant: Bool {
        guard let assistantConversation else { return false }
        let query = searchText.trimmed
        return query.isEmpty || assistantConversation.matches(query)
    }

    /// True when the user has never messaged anyone.
    var hasNoConversations: Bool {
        conversations.allSatisfy { $0.kind == .assistant }
    }

    /// True when a search is active but matches nothing.
    var hasNoMatches: Bool {
        !searchText.trimmed.isEmpty && !showsAssistant && filteredConversations.isEmpty
    }

    /// Total unread messages across every thread — feeds the tab badge.
    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + max(0, $1.unreadCount) }
    }

    // MARK: - Loading

    /// Loads the conversation list and the assistant thread concurrently.
    ///
    /// Safe to call repeatedly (pull-to-refresh, sign-in changes). A refresh
    /// that fails while content is already on screen surfaces a toast instead
    /// of blanking the list.
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            conversations = []
            phase = .loaded
            return
        }
        if conversations.isEmpty { phase = .loading }

        do {
            async let listTask = deps.chat.conversations(userID: user.id)
            async let assistantTask = deps.chat.assistantConversation(userID: user.id)

            var loaded = try await listTask
            let assistant = try await assistantTask
            if !loaded.contains(where: { $0.id == assistant.id }) {
                loaded.append(assistant)
            }
            conversations = loaded.sorted {
                ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
            }
            phase = .loaded
        } catch {
            let message = ChatErrorCopy.loadFailure(error)
            if conversations.isEmpty {
                phase = .failed(message)
            } else {
                toast = .error(message)
            }
        }
    }

    // MARK: - Mutations

    /// Clears a conversation's unread badge, optimistically and immediately.
    ///
    /// A failed write restores the previous count so the badge never lies
    /// about server state.
    func markRead(_ conversation: Conversation, using deps: PRVDependencies) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        let previousCount = conversations[index].unreadCount
        guard previousCount > 0 else { return }

        conversations[index].unreadCount = 0
        PRVHaptics.tap()

        do {
            try await deps.chat.markRead(conversationID: conversation.id)
        } catch {
            if let restoreIndex = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[restoreIndex].unreadCount = previousCount
            }
            toast = .warning(ChatErrorCopy.loadFailure(error))
        }
    }

    /// Clears every unread badge in one pass.
    func markAllRead(using deps: PRVDependencies) async {
        let unread = conversations.filter { $0.unreadCount > 0 }
        guard !unread.isEmpty else { return }
        for conversation in unread {
            await markRead(conversation, using: deps)
        }
    }
}

// MARK: - Search

extension Conversation {
    /// Case- and diacritic-insensitive match against the row's visible text.
    func matches(_ query: String) -> Bool {
        let haystack = [title, lastMessagePreview ?? ""]
        return haystack.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// SF Symbol representing the kind of thread.
    var symbolName: String {
        switch kind {
        case .clientSalon: "building.2.fill"
        case .clientProfessional: "person.fill"
        case .assistant: "sparkles"
        case .support: "lifepreserver.fill"
        }
    }

    /// Short descriptor used beneath the title when there is no preview yet.
    var kindDescription: String {
        switch kind {
        case .clientSalon: "Salon"
        case .clientProfessional: "Professional"
        case .assistant: "Your personal beauty concierge"
        case .support: "PRV Support"
        }
    }
}
