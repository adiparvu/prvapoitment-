import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Media opened full screen from a bubble.
struct ChatMediaPreview: Identifiable, Hashable, Sendable {
    /// What the viewer should present.
    enum Kind: Hashable, Sendable {
        case photo
        case video
    }

    /// Location of the image or movie.
    var url: URL
    /// Whether the viewer shows a zoomable image or a player.
    var kind: Kind
    /// Caption shown beneath the media, when the message carried one.
    var caption: String?

    var id: String { "\(kind)-\(url.absoluteString)" }
}

/// Screen model backing ``ConversationView``.
///
/// Owns the transcript, the entities its structured messages reference
/// (services for appointment requests, resolved plans for assistant
/// recommendations), optimistic sending with retry, and the live message
/// stream — including the brief "typing" beat that precedes an inbound
/// message so replies land with a natural rhythm.
@Observable
@MainActor
final class ConversationModel {
    /// How long the typing indicator shows before an inbound message lands.
    static let inboundTypingBeat: Duration = .milliseconds(320)

    /// The thread this model represents.
    let conversationID: Conversation.ID

    private(set) var phase: ChatPhase = .loading
    private(set) var conversation: Conversation?
    private(set) var messages: [ChatMessage] = []
    /// Pre-computed transcript rows — rebuilt on mutation, never in `body`.
    private(set) var timeline: [ChatTimelineItem] = []
    /// Services referenced by `appointmentRequest` messages.
    private(set) var services: [SalonService.ID: SalonService] = [:]
    /// Resolved cards for `recommendation` messages.
    private(set) var plans: [AssistantRecommendation.ID: AssistantPlan] = [:]
    /// True while an inbound message is arriving on the live stream.
    private(set) var isCounterpartTyping = false
    /// Number of messages currently in flight.
    private(set) var sendingCount = 0

    /// The composer's text.
    var draft = ""
    /// Transient feedback for send failures and attachment problems.
    var toast: PRVToast?
    /// Media currently shown full screen.
    var fullScreenMedia: ChatMediaPreview?
    /// Whether the "request an appointment" sheet is up.
    var isRequestingAppointment = false

    /// Creates a model for one conversation; call ``load(for:using:)``.
    init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }

    // MARK: - Derived state

    /// Whether a message is currently being delivered.
    var isSending: Bool { sendingCount > 0 }

    /// Display name of the other side of the conversation.
    var counterpartName: String { conversation?.title ?? "Conversation" }

    /// Avatar of the other side of the conversation.
    var counterpartAvatarURL: URL? { conversation?.avatarURL }

    /// Whether this thread talks to the AI assistant rather than a person.
    var isAssistantThread: Bool { conversation?.kind == .assistant }

    /// Salon behind the thread, when there is one — enables appointment
    /// requests from the attachment menu.
    var salonID: Salon.ID? { conversation?.salonID }

    /// The one-tap replies offered while the composer is empty.
    var quickReplies: [String] {
        ["Running 5 min late", "Can I reschedule?", "Thank you!"]
    }

    /// Whether the transcript has nothing in it yet.
    var isEmpty: Bool { messages.isEmpty }

    // MARK: - Loading

    /// Loads the conversation, its transcript, and everything the structured
    /// messages reference.
    /// - Parameters:
    ///   - user: The signed-in user, used to scope the conversation lookup.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, using deps: PRVDependencies) async {
        if messages.isEmpty { phase = .loading }
        do {
            async let messagesTask = deps.chat.messages(conversationID: conversationID)
            let loadedConversation = await resolveConversation(for: user, using: deps)
            let loadedMessages = try await messagesTask

            conversation = loadedConversation
            apply(loadedMessages)
            phase = .loaded

            await resolveReferences(in: loadedMessages, using: deps)
        } catch {
            let message = ChatErrorCopy.loadFailure(error)
            if messages.isEmpty {
                phase = .failed(message)
            } else {
                toast = .error(message)
            }
        }
    }

    /// Finds the conversation metadata. A failure here is not fatal — the
    /// transcript still renders, titled generically.
    private func resolveConversation(for user: User?, using deps: PRVDependencies) async -> Conversation? {
        guard let user else { return conversation }
        guard let all = try? await deps.chat.conversations(userID: user.id) else { return conversation }
        return all.first { $0.id == conversationID } ?? conversation
    }

    /// Clears the unread badge for this thread. Called when the transcript
    /// appears, and again whenever a new inbound message arrives while the
    /// user is looking at it.
    func markRead(using deps: PRVDependencies) async {
        // Defaults to 1 when the metadata has not arrived yet, so the first
        // appearance always clears the badge server-side.
        guard (conversation?.unreadCount ?? 1) > 0 else { return }
        try? await deps.chat.markRead(conversationID: conversationID)
        conversation?.unreadCount = 0
    }

    // MARK: - Live updates

    /// Consumes the live message stream until the task is cancelled.
    ///
    /// Inbound messages are announced with a short typing beat so a reply
    /// appears the way a person would send it, then inserted and marked read.
    func observeLiveMessages(for user: User?, using deps: PRVDependencies) async {
        let stream = deps.chat.liveMessages(conversationID: conversationID)
        for await message in stream {
            guard !Task.isCancelled else { return }
            guard message.conversationID == conversationID else { continue }

            let isMine = user.map { message.senderID == $0.id } ?? false
            if !isMine {
                isCounterpartTyping = true
                try? await Task.sleep(for: Self.inboundTypingBeat)
                isCounterpartTyping = false
            }

            upsert(message)
            await resolveReferences(in: [message], using: deps)
            if !isMine {
                PRVHaptics.tap()
                await markRead(using: deps)
            }
        }
        isCounterpartTyping = false
    }

    // MARK: - Sending

    /// Sends the composer's text, clearing the field optimistically.
    func sendDraft(as user: User, using deps: PRVDependencies) async {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        draft = ""
        await send(.text(text), as: user, using: deps)
    }

    /// Sends a one-tap quick reply.
    func sendQuickReply(_ text: String, as user: User, using deps: PRVDependencies) async {
        await send(.text(text), as: user, using: deps)
    }

    /// Stores picked photo data locally and sends it as a photo message.
    ///
    /// The write happens off the main actor — a full-resolution photo is far
    /// too much I/O to do while the composer animates.
    func sendPhoto(
        data: Data,
        fileExtension: String,
        caption: String?,
        as user: User,
        using deps: PRVDependencies
    ) async {
        let conversationID = conversationID
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ChatAttachmentStore.store(
                    data,
                    fileExtension: fileExtension,
                    in: conversationID
                )
            }.value
            await send(.photo(url, caption: caption), as: user, using: deps)
        } catch {
            toast = .error("That photo couldn't be attached. Try another one.")
            PRVHaptics.error()
        }
    }

    /// Moves a picked movie into local storage and sends it as a video.
    func sendVideo(
        pickedAt source: URL,
        caption: String?,
        as user: User,
        using deps: PRVDependencies
    ) async {
        let conversationID = conversationID
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ChatAttachmentStore.adopt(source, in: conversationID)
            }.value
            await send(.video(url, caption: caption), as: user, using: deps)
        } catch {
            toast = .error("That video couldn't be attached. Try another one.")
            PRVHaptics.error()
        }
    }

    /// Sends a structured appointment request the salon can act on.
    func sendAppointmentRequest(
        serviceID: SalonService.ID,
        preferredDate: Date,
        as user: User,
        using deps: PRVDependencies
    ) async {
        await send(
            .appointmentRequest(serviceID: serviceID, preferredDate: preferredDate),
            as: user,
            using: deps
        )
        await resolveService(serviceID, using: deps)
    }

    /// Re-sends a message that previously failed.
    func retry(_ message: ChatMessage, using deps: PRVDependencies) async {
        var retried = message
        retried.deliveryState = .sending
        retried.sentAt = .now
        await deliver(retried, using: deps)
    }

    /// Builds an outgoing message and delivers it optimistically.
    private func send(
        _ content: ChatMessage.Content,
        as user: User,
        using deps: PRVDependencies
    ) async {
        let message = ChatMessage(
            conversationID: conversationID,
            senderID: user.id,
            content: content,
            deliveryState: .sending,
            sentAt: .now
        )
        await deliver(message, using: deps)
    }

    /// Inserts the message immediately, then reconciles with the server's
    /// version — or marks it failed so the bubble offers a retry.
    private func deliver(_ message: ChatMessage, using deps: PRVDependencies) async {
        upsert(message)
        sendingCount += 1
        defer { sendingCount -= 1 }

        do {
            let confirmed = try await deps.chat.send(message)
            replace(id: message.id, with: confirmed)
            conversation?.lastMessagePreview = ChatFormat.preview(confirmed.content)
            conversation?.lastMessageAt = confirmed.sentAt
            PRVHaptics.tap()
        } catch {
            var failed = message
            failed.deliveryState = .failed
            upsert(failed)
            toast = .error(ChatErrorCopy.sendFailure(error))
            PRVHaptics.error()
        }
    }

    // MARK: - Reference resolution

    /// Resolves the services and recommendations referenced by `batch`.
    private func resolveReferences(in batch: [ChatMessage], using deps: PRVDependencies) async {
        var pendingServiceIDs: Set<SalonService.ID> = []
        var pendingRecommendations: [AssistantRecommendation] = []

        for message in batch {
            switch message.content {
            case .appointmentRequest(let serviceID, _):
                if services[serviceID] == nil { pendingServiceIDs.insert(serviceID) }
            case .recommendation(let recommendation):
                if plans[recommendation.id] == nil { pendingRecommendations.append(recommendation) }
            case .text, .photo, .video, .voice:
                continue
            }
        }

        for serviceID in pendingServiceIDs {
            await resolveService(serviceID, using: deps)
        }
        for recommendation in pendingRecommendations {
            plans[recommendation.id] = await AssistantPlanResolver.resolve(recommendation, using: deps)
        }
    }

    /// Fetches one service, ignoring failures — the card degrades to its
    /// skeleton rather than breaking the transcript.
    private func resolveService(_ id: SalonService.ID, using deps: PRVDependencies) async {
        guard services[id] == nil else { return }
        guard let service = try? await deps.salons.service(id: id) else { return }
        services[id] = service
    }

    // MARK: - Transcript maintenance

    /// Replaces the whole transcript.
    private func apply(_ newMessages: [ChatMessage]) {
        messages = newMessages.sorted { $0.sentAt < $1.sentAt }
        rebuildTimeline()
    }

    /// Inserts or updates one message in place, keeping the order by time.
    private func upsert(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messages.sort { $0.sentAt < $1.sentAt }
        rebuildTimeline()
    }

    /// Swaps an optimistic message for the server's confirmed version, which
    /// may carry a different identifier.
    private func replace(id: ChatMessage.ID, with confirmed: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = confirmed
        } else {
            messages.append(confirmed)
        }
        messages.sort { $0.sentAt < $1.sentAt }
        rebuildTimeline()
    }

    /// Recomputes the day headers and author runs.
    private func rebuildTimeline() {
        timeline = ChatTimeline.build(from: messages)
    }
}
