import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model backing ``BeautyAssistantView``.
///
/// Owns the persisted assistant thread: it loads the user's dedicated
/// conversation, writes both sides of every exchange back through
/// `ChatRepository.send` so the plan survives app launches, and resolves each
/// `AssistantRecommendation` into a fully populated ``AssistantPlan``.
@Observable
@MainActor
final class AssistantModel {
    /// Openers offered before the client has said anything.
    static let openingSuggestions = [
        "I have a wedding in two weeks",
        "I want a balayage",
        "My nails break easily",
        "I want a complete makeover",
    ]

    /// Follow-ups offered once there is an answer on screen.
    static let followUpSuggestions = [
        "How do I maintain this?",
        "Show me something bolder",
        "What fits a smaller budget?",
    ]

    private(set) var phase: ChatPhase = .loading
    private(set) var conversation: Conversation?
    private(set) var messages: [ChatMessage] = []
    /// Pre-computed transcript rows — never rebuilt inside `body`.
    private(set) var timeline: [ChatTimelineItem] = []
    /// Resolved cards, keyed by recommendation.
    private(set) var plans: [AssistantRecommendation.ID: AssistantPlan] = [:]
    /// True while the assistant is composing an answer.
    private(set) var isThinking = false
    /// The prompt being answered, echoed by the thinking card.
    private(set) var pendingPrompt: String?
    /// A prompt that failed, kept for one-tap retry.
    private(set) var failedPrompt: String?
    /// Human copy for the failed request.
    private(set) var errorMessage: String?

    /// The composer's text.
    var draft = ""
    /// Transient feedback for background failures.
    var toast: PRVToast?

    /// Creates an empty model; call ``load(for:using:)`` to populate it.
    init() {}

    // MARK: - Derived state

    /// Whether anything has been said yet.
    var hasThread: Bool { !messages.isEmpty }

    /// Suggestions shown in the composer, once the hero has been replaced.
    var composerSuggestions: [String] {
        hasThread ? Self.followUpSuggestions : []
    }

    // MARK: - Loading

    /// Loads the user's assistant thread and resolves every recommendation
    /// it already contains.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            messages = []
            rebuildTimeline()
            phase = .loaded
            return
        }
        if messages.isEmpty { phase = .loading }

        do {
            let thread = try await deps.chat.assistantConversation(userID: user.id)
            conversation = thread
            let history = try await deps.chat.messages(conversationID: thread.id)
            messages = history.sorted { $0.sentAt < $1.sentAt }
            rebuildTimeline()
            phase = .loaded

            await resolvePlans(in: messages, using: deps)
            try? await deps.chat.markRead(conversationID: thread.id)
            conversation?.unreadCount = 0
        } catch {
            let message = ChatErrorCopy.loadFailure(error)
            if messages.isEmpty {
                phase = .failed(message)
            } else {
                toast = .error(message)
            }
        }
    }

    // MARK: - Asking

    /// Sends whatever is in the composer.
    func submitDraft(as user: User, using deps: PRVDependencies) async {
        let prompt = draft.trimmed
        guard !prompt.isEmpty else { return }
        draft = ""
        await ask(prompt, as: user, using: deps)
    }

    /// Re-runs the prompt that failed.
    func retryFailedPrompt(as user: User, using deps: PRVDependencies) async {
        guard let failedPrompt else { return }
        await ask(failedPrompt, as: user, using: deps)
    }

    /// Asks the assistant, persisting both the question and the answer into
    /// the user's assistant conversation.
    ///
    /// The question is written first so the thread reads correctly even if
    /// the answer fails; a failed answer leaves the prompt available for
    /// retry rather than losing it.
    func ask(_ rawPrompt: String, as user: User, using deps: PRVDependencies) async {
        let prompt = rawPrompt.trimmed
        guard !prompt.isEmpty, !isThinking else { return }

        guard let threadID = await ensureThread(for: user, using: deps) else {
            errorMessage = "Your assistant thread couldn't be opened. Try again."
            failedPrompt = prompt
            PRVHaptics.error()
            return
        }

        errorMessage = nil
        failedPrompt = nil

        await persistQuestion(prompt, threadID: threadID, as: user, using: deps)

        isThinking = true
        pendingPrompt = prompt
        defer {
            isThinking = false
            pendingPrompt = nil
        }

        do {
            let recommendation = try await deps.chat.askAssistant(prompt: prompt, userID: user.id)
            let answer = ChatMessage(
                conversationID: threadID,
                senderID: nil,
                isFromAssistant: true,
                content: .recommendation(recommendation),
                deliveryState: .delivered
            )
            let stored = (try? await deps.chat.send(answer)) ?? answer
            insert(stored)
            plans[recommendation.id] = await AssistantPlanResolver.resolve(recommendation, using: deps)
            conversation?.lastMessagePreview = recommendation.headline
            conversation?.lastMessageAt = stored.sentAt
            PRVHaptics.success()
        } catch {
            errorMessage = ChatErrorCopy.assistantFailure(error)
            failedPrompt = prompt
            PRVHaptics.error()
        }
    }

    /// Re-sends a question whose write failed.
    func retryMessage(_ message: ChatMessage, using deps: PRVDependencies) async {
        var retried = message
        retried.deliveryState = .sending
        retried.sentAt = .now
        insert(retried)
        if let stored = try? await deps.chat.send(retried) {
            replace(retried.id, with: stored)
        } else {
            retried.deliveryState = .failed
            insert(retried)
            toast = .error("That message didn't send. Try again.")
        }
    }

    // MARK: - Internals

    /// Returns the assistant thread, creating it on first use.
    private func ensureThread(for user: User, using deps: PRVDependencies) async -> Conversation.ID? {
        if let existing = conversation?.id { return existing }
        guard let created = try? await deps.chat.assistantConversation(userID: user.id) else {
            return nil
        }
        conversation = created
        return created.id
    }

    /// Writes the client's question into the thread, optimistically.
    private func persistQuestion(
        _ prompt: String,
        threadID: Conversation.ID,
        as user: User,
        using deps: PRVDependencies
    ) async {
        var question = ChatMessage(
            conversationID: threadID,
            senderID: user.id,
            content: .text(prompt),
            deliveryState: .sending,
            sentAt: .now
        )
        insert(question)

        if let stored = try? await deps.chat.send(question) {
            replace(question.id, with: stored)
        } else {
            question.deliveryState = .failed
            insert(question)
        }
    }

    /// Resolves every recommendation in `batch` that has no card yet.
    private func resolvePlans(in batch: [ChatMessage], using deps: PRVDependencies) async {
        for message in batch {
            guard case .recommendation(let recommendation) = message.content else { continue }
            guard plans[recommendation.id] == nil else { continue }
            plans[recommendation.id] = await AssistantPlanResolver.resolve(recommendation, using: deps)
        }
    }

    /// Inserts or updates a message and refreshes the transcript.
    private func insert(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messages.sort { $0.sentAt < $1.sentAt }
        rebuildTimeline()
    }

    /// Swaps an optimistic message for the server's confirmed version.
    private func replace(_ id: ChatMessage.ID, with confirmed: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = confirmed
        } else {
            messages.append(confirmed)
        }
        messages.sort { $0.sentAt < $1.sentAt }
        rebuildTimeline()
    }

    private func rebuildTimeline() {
        timeline = ChatTimeline.build(from: messages)
    }
}
