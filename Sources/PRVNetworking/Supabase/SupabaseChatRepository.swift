import Foundation
import PRVFoundation
import PRVModels

/// The live ``ChatRepository``, backed by the `conversations`,
/// `conversation_participants`, and `messages` tables plus the
/// `assistant-recommend` Edge Function.
///
/// `ChatMessage.Content` is an enum with associated values, and `messages`
/// stores it discriminated — `content_kind` plus the payload columns — so a
/// transcript stays queryable instead of becoming an opaque blob. The mapping in
/// both directions lives in this file and is exhaustive over the enum, so a new
/// content case cannot be added without deciding how it is stored.
///
/// Unread counts are derived, never stored: `conversation_participants.last_read_at`
/// is the read cursor, and a message is unread when it arrived after that cursor
/// and somebody else sent it — the same definition ``markRead(conversationID:)``
/// settles by moving the cursor forward.
public struct SupabaseChatRepository: ChatRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns.
    fileprivate static let listLimit = 200

    /// The conversation projection: the row plus its participants and their read
    /// cursors, which is everything `Conversation` needs.
    private static let conversationColumns = "*,conversation_participants(user_id,last_read_at)"

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Reads

    /// The user's conversations, most recently active first.
    ///
    /// No participant filter is sent: `conversations_select_participant` returns
    /// only conversations the caller belongs to, so the policy already describes
    /// exactly this set and a client-side filter could only ever disagree with
    /// it. Ordering asks for nulls last, so a thread that has never carried a
    /// message sits at the bottom rather than at the top.
    public func conversations(userID: User.ID) async throws -> [Conversation] {
        let request = PostgRESTQuery("conversations")
            .selecting(Self.conversationColumns)
            .order("last_message_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [ConversationRow] = try await client.select(request)
        guard !rows.isEmpty else { return [] }

        let unread = try await unreadCounts(for: rows, userID: userID)
        return rows.map { Self.makeConversation($0, unreadCount: unread[$0.id] ?? 0) }
    }

    /// A conversation's transcript, oldest first.
    public func messages(conversationID: Conversation.ID) async throws -> [ChatMessage] {
        let request = PostgRESTQuery("messages")
            .filter(.equals("conversation_id", conversationID.rawValue))
            .order("sent_at")
            .limited(to: Self.listLimit)
        let rows: [MessageRow] = try await client.select(request)
        return try rows.map(Self.makeMessage)
    }

    // MARK: - Writes

    /// Persists a message and refreshes its conversation's summary.
    ///
    /// The row is written `delivered`: the server has it, which is precisely what
    /// that state means, and it is what `InMemoryBackend` returns. The
    /// conversation's preview changes only for text — a photo or a voice note
    /// leaves the last readable line in place rather than blanking the list row —
    /// while `last_message_at` always advances so ordering stays honest.
    public func send(_ message: ChatMessage) async throws -> ChatMessage {
        let row: MessageRow = try await client.insert(
            into: "messages",
            values: Self.makeInsert(message)
        )
        let delivered = try Self.makeMessage(row)

        _ = try await client.update(
            "conversations",
            values: ConversationSummaryUpdate(content: message.content, lastMessageAt: row.sentAt),
            filters: [.equals("id", message.conversationID.rawValue)],
            returning: "id",
            singleRow: false,
            as: [ConversationIdentifierRow].self
        )
        return delivered
    }

    /// Moves the caller's read cursor to now, clearing the unread badge.
    ///
    /// `conversation_participants_update_own` restricts the statement to rows
    /// where `user_id = auth.uid()`, so the caller's own row is the only one this
    /// can reach even before the explicit filter is added. Marking a conversation
    /// the caller does not belong to touches nothing and is not an error, which
    /// is why no single row is demanded of the response.
    public func markRead(conversationID: Conversation.ID) async throws {
        var filters: [PostgRESTFilter] = [.equals("conversation_id", conversationID.rawValue)]
        if let userID = await client.currentUserID {
            filters.append(.equals("user_id", userID))
        }
        _ = try await client.update(
            "conversation_participants",
            values: ReadCursorUpdate(lastReadAt: SupabaseTimestamp.string(from: .now)),
            filters: filters,
            returning: "user_id",
            singleRow: false,
            as: [ConversationParticipantRow].self
        )
    }

    /// Streams messages that arrive after the caller starts listening.
    ///
    /// This is a polling feed, and deliberately so. Supabase Realtime needs the
    /// project's socket URL, its API key, and the caller's access token; two of
    /// the three are private to ``SupabaseClient``, so a socket opened here would
    /// have to keep a second, divergent copy of session state the transport
    /// already owns — including its refresh. Polling through the same client
    /// inherits the authentication, the refresh, and the RLS for free, and the
    /// seam stays cheap to move: this method hands back an `AsyncStream` and
    /// nothing above it knows how the elements were produced.
    ///
    /// The loop backs off while a thread is quiet and snaps back to its fastest
    /// interval the moment anything arrives, so an idle transcript costs about a
    /// request a minute rather than one every few seconds.
    public func liveMessages(conversationID: Conversation.ID) -> AsyncStream<ChatMessage> {
        let client = self.client
        let start = Date.now
        return AsyncStream { continuation in
            let feed = LiveMessageFeed(client: client, conversationID: conversationID, since: start)
            let task = Task {
                await feed.run(yielding: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Assistant

    /// Asks the AI Beauty Assistant for recommendations.
    ///
    /// The whole exchange happens inside `assistant-recommend`: the model key
    /// never leaves the server, the candidate catalogue is read with the caller's
    /// own JWT — so nothing RLS hides is ever shown to the model — and every
    /// identifier it returns is checked back against that catalogue before the
    /// response is sent. `userID` is not part of the request because the function
    /// takes the caller from the bearer token; a client-supplied identifier would
    /// be an assertion rather than a proof.
    ///
    /// No conversation is named, so asking appends nothing to a transcript.
    public func askAssistant(prompt: String, userID: User.ID) async throws -> AssistantRecommendation {
        try await client.invoke(
            function: "assistant-recommend",
            body: AssistantRequest(prompt: prompt),
            as: AssistantRecommendation.self
        )
    }

    /// The user's assistant thread, created on first use.
    public func assistantConversation(userID: User.ID) async throws -> Conversation {
        let request = PostgRESTQuery("conversations")
            .selecting(Self.conversationColumns)
            .filter(.equals("kind", Conversation.Kind.assistant.rawValue))
            .order("created_at")
            .limited(to: 1)
        let existing: [ConversationRow] = try await client.select(request)
        if let row = existing.first {
            let unread = try await unreadCounts(for: [row], userID: userID)
            return Self.makeConversation(row, unreadCount: unread[row.id] ?? 0)
        }

        let created: ConversationRow = try await client.insert(
            into: "conversations",
            values: ConversationInsert(kind: Conversation.Kind.assistant.rawValue, title: Self.assistantTitle)
        )
        _ = try await client.insert(
            into: "conversation_participants",
            values: ConversationParticipantInsert(conversationID: created.id, userID: userID.rawValue),
            returning: "user_id",
            as: ConversationParticipantRow.self
        )

        // An insert response carries base columns only, so the participant just
        // written is attached here rather than read back.
        var conversation = Self.makeConversation(created, unreadCount: 0)
        conversation.participantIDs = [userID]
        return conversation
    }

    /// The title a freshly created assistant thread is given.
    private static let assistantTitle = "Beauty Assistant"

    // MARK: - Unread

    /// Unread counts keyed by conversation.
    ///
    /// One extra request covers every thread: the earliest read cursor bounds a
    /// single `messages` query, and each conversation is then counted against its
    /// own cursor. Messages the caller sent are never unread, and a conversation
    /// the caller has no participant row for is not counted at all.
    private func unreadCounts(for rows: [ConversationRow], userID: User.ID) async throws -> [UUID: Int] {
        var cursors: [UUID: Date] = [:]
        for row in rows {
            guard let cursor = Self.readCursor(in: row, for: userID.rawValue) else { continue }
            cursors[row.id] = cursor
        }
        guard let earliest = cursors.values.min() else { return [:] }

        let request = PostgRESTQuery("messages")
            .selecting("conversation_id,sender_id,sent_at")
            .filter(.within("conversation_id", Array(cursors.keys)))
            .filter(.atLeast("sent_at", SupabaseTimestamp.string(from: earliest)))
            .limited(to: Self.listLimit)
        let recent: [UnreadMessageRow] = try await client.select(request)

        var counts: [UUID: Int] = [:]
        for message in recent {
            guard let cursor = cursors[message.conversationID] else { continue }
            guard let sentAt = SupabaseTimestamp.optionalDate(from: message.sentAt), sentAt > cursor else {
                continue
            }
            guard message.senderID != userID.rawValue else { continue }
            counts[message.conversationID, default: 0] += 1
        }
        return counts
    }

    /// The caller's read cursor within an embedded participant list.
    private static func readCursor(in row: ConversationRow, for userID: UUID) -> Date? {
        guard let participant = (row.conversationParticipants?.values ?? [])
            .first(where: { $0.userID == userID })
        else { return nil }
        return SupabaseTimestamp.optionalDate(from: participant.lastReadAt)
    }

    // MARK: - Row mapping

    private static func makeConversation(_ row: ConversationRow, unreadCount: Int) -> Conversation {
        Conversation(
            id: Conversation.ID(row.id),
            kind: Conversation.Kind(rawValue: row.kind) ?? .clientSalon,
            title: row.title,
            avatarURL: row.avatarURL.flatMap(URL.init(string:)),
            participantIDs: (row.conversationParticipants?.values ?? []).map { User.ID($0.userID) },
            salonID: row.salonID.map { Salon.ID($0) },
            lastMessagePreview: row.lastMessagePreview,
            lastMessageAt: SupabaseTimestamp.optionalDate(from: row.lastMessageAt),
            unreadCount: unreadCount,
            isEncrypted: row.isEncrypted
        )
    }

    /// Rebuilds a message, including the content enum its payload columns encode.
    fileprivate static func makeMessage(_ row: MessageRow) throws -> ChatMessage {
        ChatMessage(
            id: ChatMessage.ID(row.id),
            conversationID: Conversation.ID(row.conversationID),
            senderID: row.senderID.map { User.ID($0) },
            isFromAssistant: row.isFromAssistant,
            content: try makeContent(row),
            deliveryState: ChatMessage.DeliveryState(rawValue: row.deliveryState) ?? .sent,
            sentAt: try SupabaseTimestamp.date(from: row.sentAt)
        )
    }

    /// Rebuilds the content enum from its discriminator and payload columns.
    ///
    /// The database enforces most of this with check constraints
    /// (`messages_media_has_url`, `messages_request_has_service`, …); the throws
    /// below cover a row written before one of them existed. An unrecognized
    /// discriminator reads as text, which is what an older client should do with
    /// a content kind it was built too early to know about.
    private static func makeContent(_ row: MessageRow) throws -> ChatMessage.Content {
        switch MessageContentKind(rawValue: row.contentKind) ?? .text {
        case .text:
            return .text(row.body ?? "")
        case .photo:
            return .photo(try media(in: row), caption: row.caption)
        case .video:
            return .video(try media(in: row), caption: row.caption)
        case .voice:
            return .voice(try media(in: row), durationSeconds: row.durationSeconds ?? 0)
        case .appointmentRequest:
            guard let serviceID = row.serviceID,
                  let preferredDate = SupabaseTimestamp.optionalDate(from: row.preferredDate)
            else {
                throw APIError.decoding("Message \(row.id) is an appointment request without a service or date.")
            }
            return .appointmentRequest(serviceID: SalonService.ID(serviceID), preferredDate: preferredDate)
        case .recommendation:
            guard let recommendation = row.recommendation else {
                throw APIError.decoding("Message \(row.id) is a recommendation without a payload.")
            }
            return .recommendation(recommendation)
        }
    }

    /// The media URL a photo, video, or voice note must carry.
    private static func media(in row: MessageRow) throws -> URL {
        guard let text = row.mediaURL, let url = URL(string: text) else {
            throw APIError.decoding("Message \(row.id) is missing a usable media URL.")
        }
        return url
    }

    /// Flattens a message's content across the payload columns the schema
    /// defines for it.
    private static func makeInsert(_ message: ChatMessage) -> MessageInsert {
        switch message.content {
        case .text(let text):
            MessageInsert(message: message, contentKind: .text, body: text)
        case .photo(let url, let caption):
            MessageInsert(message: message, contentKind: .photo, mediaURL: url.absoluteString, caption: caption)
        case .video(let url, let caption):
            MessageInsert(message: message, contentKind: .video, mediaURL: url.absoluteString, caption: caption)
        case .voice(let url, let seconds):
            MessageInsert(
                message: message,
                contentKind: .voice,
                mediaURL: url.absoluteString,
                durationSeconds: seconds
            )
        case .appointmentRequest(let serviceID, let preferredDate):
            MessageInsert(
                message: message,
                contentKind: .appointmentRequest,
                serviceID: serviceID.rawValue,
                preferredDate: preferredDate
            )
        case .recommendation(let recommendation):
            MessageInsert(message: message, contentKind: .recommendation, recommendation: recommendation)
        }
    }
}

// MARK: - Live feed

/// Polls one conversation for messages newer than a moving cursor.
///
/// An actor so the cursor and the de-duplication set are mutated from exactly one
/// place, and so the stream's task is the only thing that ever touches them.
private actor LiveMessageFeed {
    /// How often a busy thread is polled.
    private static let fastestInterval: Double = 3
    /// The ceiling a quiet thread backs off to.
    private static let slowestInterval: Double = 60

    private let client: SupabaseClient
    private let conversationID: Conversation.ID
    private var cursor: Date
    private var delivered: Set<UUID> = []

    init(client: SupabaseClient, conversationID: Conversation.ID, since: Date) {
        self.client = client
        self.conversationID = conversationID
        self.cursor = since
    }

    /// Yields new messages until the consuming task is cancelled.
    func run(yielding continuation: AsyncStream<ChatMessage>.Continuation) async {
        var interval = Self.fastestInterval
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break // Cancelled while waiting: the consumer has gone away.
            }
            guard !Task.isCancelled else { break }

            let fresh = await poll()
            if fresh.isEmpty {
                interval = min(Self.slowestInterval, interval * 2)
            } else {
                interval = Self.fastestInterval
                for message in fresh {
                    continuation.yield(message)
                }
            }
        }
        continuation.finish()
    }

    /// Reads everything at or after the cursor and returns what has not been
    /// delivered yet.
    ///
    /// The filter is inclusive and de-duplication is by identifier, because two
    /// messages can share a timestamp and an exclusive cursor would drop the
    /// second one. A failed poll is logged and treated as "nothing new" — a
    /// dropped connection must not end a stream the user is still watching.
    private func poll() async -> [ChatMessage] {
        do {
            let request = PostgRESTQuery("messages")
                .filter(.equals("conversation_id", conversationID.rawValue))
                .filter(.atLeast("sent_at", SupabaseTimestamp.string(from: cursor)))
                .order("sent_at")
                .limited(to: SupabaseChatRepository.listLimit)
            let rows: [SupabaseChatRepository.MessageRow] = try await client.select(request)

            var fresh: [ChatMessage] = []
            for row in rows where !delivered.contains(row.id) {
                let message = try SupabaseChatRepository.makeMessage(row)
                delivered.insert(row.id)
                if message.sentAt > cursor { cursor = message.sentAt }
                fresh.append(message)
            }
            return fresh
        } catch {
            PRVLog.chat.error(
                "Live message poll failed for \(conversationID.description, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }
}

// MARK: - Rows

extension SupabaseChatRepository {
    /// A `conversations` row plus its embedded participants and read cursors.
    fileprivate struct ConversationRow: Decodable, Sendable {
        let id: UUID
        let kind: String
        let title: String
        let avatarURL: String?
        let salonID: UUID?
        let lastMessagePreview: String?
        let lastMessageAt: String?
        let isEncrypted: Bool
        let conversationParticipants: SupabaseEmbedded<ConversationParticipantRow>?
    }

    /// A `conversation_participants` row.
    fileprivate struct ConversationParticipantRow: Decodable, Sendable {
        let userID: UUID
        let lastReadAt: String?
    }

    /// The identifier PostgREST echoes back from a `conversations` write.
    fileprivate struct ConversationIdentifierRow: Decodable, Sendable {
        let id: UUID
    }

    /// A `messages` row, content discriminator and payload columns included.
    fileprivate struct MessageRow: Decodable, Sendable {
        let id: UUID
        let conversationID: UUID
        let senderID: UUID?
        let isFromAssistant: Bool
        let contentKind: String
        let body: String?
        let mediaURL: String?
        let caption: String?
        let durationSeconds: Int?
        let serviceID: UUID?
        let preferredDate: String?
        let recommendation: AssistantRecommendation?
        let deliveryState: String
        let sentAt: String
    }

    /// The three `messages` columns an unread count needs.
    fileprivate struct UnreadMessageRow: Decodable, Sendable {
        let conversationID: UUID
        let senderID: UUID?
        let sentAt: String
    }

    /// The `message_content_kind` discriminator.
    fileprivate enum MessageContentKind: String, Sendable {
        case text
        case photo
        case video
        case voice
        case appointmentRequest = "appointment_request"
        case recommendation
    }
}

// MARK: - Payloads

extension SupabaseChatRepository {
    /// A new `messages` row.
    ///
    /// Every payload column is optional and omitted when unset, so a text message
    /// writes `body` alone and leaves the media, appointment, and recommendation
    /// columns null — which is exactly what the table's check constraints expect.
    fileprivate struct MessageInsert: Encodable, Sendable {
        let id: UUID
        let conversationID: UUID
        let senderID: UUID?
        let isFromAssistant: Bool
        let contentKind: String
        let body: String?
        let mediaURL: String?
        let caption: String?
        let durationSeconds: Int?
        let serviceID: UUID?
        let preferredDate: String?
        let recommendation: AssistantRecommendation?
        let deliveryState: String
        let sentAt: String

        init(
            message: ChatMessage,
            contentKind: MessageContentKind,
            body: String? = nil,
            mediaURL: String? = nil,
            caption: String? = nil,
            durationSeconds: Int? = nil,
            serviceID: UUID? = nil,
            preferredDate: Date? = nil,
            recommendation: AssistantRecommendation? = nil
        ) {
            id = message.id.rawValue
            conversationID = message.conversationID.rawValue
            senderID = message.senderID?.rawValue
            isFromAssistant = message.isFromAssistant
            self.contentKind = contentKind.rawValue
            self.body = body
            self.mediaURL = mediaURL
            self.caption = caption
            self.durationSeconds = durationSeconds
            self.serviceID = serviceID
            self.preferredDate = preferredDate.map(SupabaseTimestamp.string(from:))
            self.recommendation = recommendation
            // The server accepting the row is what "delivered" means.
            deliveryState = ChatMessage.DeliveryState.delivered.rawValue
            sentAt = SupabaseTimestamp.string(from: message.sentAt)
        }
    }

    /// Refreshes a conversation's list-row summary.
    ///
    /// `lastMessagePreview` stays nil for non-text content, which leaves the
    /// column out of the `PATCH` entirely so the previous readable line survives.
    fileprivate struct ConversationSummaryUpdate: Encodable, Sendable {
        let lastMessagePreview: String?
        let lastMessageAt: String

        init(content: ChatMessage.Content, lastMessageAt: String) {
            if case .text(let text) = content {
                lastMessagePreview = text
            } else {
                lastMessagePreview = nil
            }
            self.lastMessageAt = lastMessageAt
        }
    }

    /// Moves a participant's read cursor.
    fileprivate struct ReadCursorUpdate: Encodable, Sendable {
        let lastReadAt: String
    }

    /// A new `conversations` row.
    fileprivate struct ConversationInsert: Encodable, Sendable {
        let kind: String
        let title: String
    }

    /// A new `conversation_participants` row.
    fileprivate struct ConversationParticipantInsert: Encodable, Sendable {
        let conversationID: UUID
        let userID: UUID
    }

    /// The `assistant-recommend` request body.
    fileprivate struct AssistantRequest: Encodable, Sendable {
        let prompt: String
    }
}
