import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// One end-to-end-encrypted conversation: the transcript anchored to its most
/// recent message, glass bubbles (the brand gradient for the client, Liquid
/// Glass for the salon), day separators, delivery ticks, and every kind of
/// message the platform can carry — text, photos, video, voice notes,
/// structured appointment requests, and assistant recommendations.
///
/// The composer sends optimistically: the bubble appears immediately, then
/// settles into `delivered` or offers a retry. Opening the screen clears the
/// unread badge.
///
/// ```swift
/// NavigationStack { ConversationView(conversationID: conversation.id) }
/// ```
public struct ConversationView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: ConversationModel

    /// Identifier of the anchor pinned to the bottom of the transcript.
    private static let bottomAnchor = "prv.chat.bottom"

    /// Opens one conversation. All dependencies come from the environment;
    /// the initializer takes only the identifier by contract.
    public init(conversationID: Conversation.ID) {
        _model = State(initialValue: ConversationModel(conversationID: conversationID))
    }

    public var body: some View {
        @Bindable var model = model

        content
            .background(Color.prv.canvas)
            .navigationTitle(model.counterpartName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .task { await start() }
            .task { await model.observeLiveMessages(for: session.currentUser, using: deps) }
            .sheet(isPresented: $model.isRequestingAppointment) { appointmentRequestSheet }
            .fullScreenCover(item: $model.fullScreenMedia) { media in
                ChatMediaViewer(media: media)
            }
            .prvToast($model.toast)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            transcriptSkeleton
        case .failed(let message):
            ScrollView {
                ChatErrorCard(message: message) {
                    Task { await start() }
                }
                .padding(PRVSpacing.md)
            }
            .refreshable { await start() }
        case .loaded:
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PRVSpacing.xs) {
                    encryptionNotice

                    if model.isEmpty {
                        conversationStarter
                    } else {
                        ForEach(model.timeline) { item in
                            row(for: item)
                        }
                    }

                    if model.isCounterpartTyping {
                        TypingIndicatorBubble(name: model.counterpartName)
                            .transition(.opacity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, PRVSpacing.md)
                .padding(.vertical, PRVSpacing.md)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .prvAnimation(PRVMotion.spring, value: model.timeline.count)
            .prvAnimation(PRVMotion.quick, value: model.isCounterpartTyping)
            .onChange(of: model.timeline.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: model.isCounterpartTyping) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var transcriptSkeleton: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.md) {
                ForEach(0..<6, id: \.self) { index in
                    HStack {
                        if index.isMultiple(of: 2) {
                            PRVSkeleton(width: 190, height: 44, radius: PRVRadius.lg)
                            Spacer(minLength: PRVSpacing.xxl)
                        } else {
                            Spacer(minLength: PRVSpacing.xxl)
                            PRVSkeleton(width: 150, height: 38, radius: PRVRadius.lg)
                        }
                    }
                }
            }
            .padding(PRVSpacing.md)
        }
        .scrollDisabled(true)
    }

    /// Reassures the client that the thread is private — shown once, above
    /// the first message.
    @ViewBuilder
    private var encryptionNotice: some View {
        if model.conversation?.isEncrypted == true {
            HStack(spacing: PRVSpacing.xxs) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text("Messages in this conversation are end-to-end encrypted.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.prv.textSecondary)
            .padding(.vertical, PRVSpacing.xs)
            .padding(.horizontal, PRVSpacing.sm)
            .prvGlassEffect()
            .frame(maxWidth: .infinity)
            .padding(.bottom, PRVSpacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    /// Friendly nudge for a thread with no history yet.
    private var conversationStarter: some View {
        PRVEmptyState(
            systemImage: "bubble.left.and.text.bubble.right",
            title: "Say hello",
            message: "Ask about availability, share an inspiration photo, or request a time — \(model.counterpartName) usually replies quickly."
        )
        .padding(.top, PRVSpacing.xl)
    }

    /// One transcript row. Built through `ContentBuilder`: the message branch
    /// resolves a whole `MessageContext` and an action set before it builds a
    /// `MessageRow`, and it does so once per item inside the timeline's
    /// `ForEach` — the screen's heaviest type-check site.
    @ContentBuilder
    private func row(for item: ChatTimelineItem) -> some View {
        switch item {
        case .dayHeader(let header):
            ChatDayHeaderRow(header: header)
        case .message(let entry):
            MessageRow(
                entry: entry,
                context: messageContext(for: entry.message),
                actions: messageActions
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(model.counterpartName)
                    .font(.headline)
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)
                if model.conversation?.isEncrypted == true {
                    HStack(spacing: 2) {
                        Image(systemName: "lock.fill")
                        Text("Encrypted")
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.prv.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }

        if let salonID = model.salonID {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    PRVHaptics.tap()
                    router.push(.salon(salonID))
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.accent)
                }
                .accessibilityLabel("Open salon profile")
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch model.phase {
        case .failed:
            EmptyView()
        case .loading, .loaded:
            PRVBottomBar {
                if session.currentUser == nil {
                    Text("Sign in to reply to this conversation.")
                        .prvStyle(.footnote)
                        .frame(maxWidth: .infinity)
                } else {
                    ConversationComposer(model: model, onIntent: handle)
                }
            }
        }
    }

    @ViewBuilder
    private var appointmentRequestSheet: some View {
        if let salonID = model.salonID {
            AppointmentRequestSheet(salonID: salonID) { serviceID, preferredDate in
                guard let user = session.currentUser else { return }
                Task {
                    await model.sendAppointmentRequest(
                        serviceID: serviceID,
                        preferredDate: preferredDate,
                        as: user,
                        using: deps
                    )
                }
            }
        }
    }

    // MARK: - Bubble wiring

    private func messageContext(for message: ChatMessage) -> MessageContext {
        let isMine = session.currentUser.map { message.senderID == $0.id } ?? false

        var service: SalonService?
        var plan: AssistantPlan?
        switch message.content {
        case .appointmentRequest(let serviceID, _):
            service = model.services[serviceID]
        case .recommendation(let recommendation):
            plan = model.plans[recommendation.id]
        case .text, .photo, .video, .voice:
            break
        }

        let name: String = if isMine {
            session.currentUser?.firstName ?? "You"
        } else if message.isFromAssistant {
            "Beauty Assistant"
        } else {
            model.counterpartName
        }

        return MessageContext(
            isMine: isMine,
            senderName: name,
            senderAvatarURL: isMine ? session.currentUser?.avatarURL : model.counterpartAvatarURL,
            salonID: model.salonID,
            service: service,
            plan: plan
        )
    }

    private var messageActions: MessageActions {
        MessageActions(
            openMedia: { media in model.fullScreenMedia = media },
            retry: { message in
                Task { await model.retry(message, using: deps) }
            },
            book: { salonID, serviceIDs in
                router.push(.booking(salonID: salonID, serviceIDs: serviceIDs))
            },
            openSalon: { router.push(.salon($0)) },
            openProfessional: { router.push(.professional($0)) },
            openPackages: { router.push(.packages(salonID: $0)) }
        )
    }

    // MARK: - Actions

    /// Loads the transcript and clears the unread badge.
    private func start() async {
        await model.load(for: session.currentUser, using: deps)
        await model.markRead(using: deps)
    }

    /// Turns a composer intent into repository work.
    private func handle(_ intent: ComposerIntent) {
        guard let user = session.currentUser else { return }
        switch intent {
        case .send:
            Task { await model.sendDraft(as: user, using: deps) }
        case .quickReply(let text):
            Task { await model.sendQuickReply(text, as: user, using: deps) }
        case .photoPicked(let item):
            Task { await importPhoto(item, as: user) }
        case .videoPicked(let item):
            Task { await importVideo(item, as: user) }
        case .requestAppointment:
            PRVHaptics.tap()
            model.isRequestingAppointment = true
        }
    }

    /// Reads picked image bytes and sends them as a photo message.
    private func importPhoto(_ item: PhotosPickerItem, as user: User) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.toast = .warning("That photo couldn't be read. Try another one.")
                return
            }
            let fileExtension = item.supportedContentTypes
                .compactMap(\.preferredFilenameExtension)
                .first ?? "jpg"
            await model.sendPhoto(
                data: data,
                fileExtension: fileExtension,
                caption: nil,
                as: user,
                using: deps
            )
        } catch {
            model.toast = .error("That photo couldn't be attached. Try another one.")
        }
    }

    /// Materializes a picked movie and sends it as a video message.
    private func importVideo(_ item: PhotosPickerItem, as user: User) async {
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                model.toast = .warning("That video couldn't be read. Try another one.")
                return
            }
            await model.sendVideo(pickedAt: movie.url, caption: nil, as: user, using: deps)
        } catch {
            model.toast = .error("That video couldn't be attached. Try another one.")
        }
    }

    /// Keeps the newest message in view as the transcript grows.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !reduceMotion else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            return
        }
        withAnimation(PRVMotion.gentle) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

/// The composer bound to one conversation model. Isolating it keeps the
/// `@Bindable` projection out of the parent's view builders.
private struct ConversationComposer: View {
    @Bindable var model: ConversationModel
    let onIntent: (ComposerIntent) -> Void

    var body: some View {
        MessageComposer(
            draft: $model.draft,
            quickReplies: model.quickReplies,
            placeholder: "Message \(model.counterpartName)",
            canRequestAppointment: model.salonID != nil,
            isSending: model.isSending,
            onIntent: onIntent
        )
    }
}

// MARK: - Previews

/// Resolves a real conversation from the in-memory backend so previews show
/// a populated transcript instead of a fabricated identifier.
private struct ConversationPreviewHost: View {
    @Environment(\.prvDependencies) private var deps

    let kind: Conversation.Kind

    @State private var conversationID: Conversation.ID?

    var body: some View {
        Group {
            if let conversationID {
                ConversationView(conversationID: conversationID)
            } else {
                Color.prv.canvas
            }
        }
        .task {
            let conversations = (try? await deps.chat.conversations(userID: PreviewData.client.id)) ?? []
            conversationID = conversations.first { $0.kind == kind }?.id
        }
    }
}

#Preview("Conversation — Client") {
    NavigationStack {
        ConversationPreviewHost(kind: .clientSalon)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .chat))
}

#Preview("Conversation — Dark") {
    NavigationStack {
        ConversationPreviewHost(kind: .clientSalon)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .chat))
    .preferredColorScheme(.dark)
}
