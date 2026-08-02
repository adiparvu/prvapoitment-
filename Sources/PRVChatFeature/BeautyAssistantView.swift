import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The AI Beauty Assistant — the platform's marquee experience.
///
/// It opens on a hero prompt with four one-tap goals; ask anything and the
/// answer arrives as a rich Liquid Glass card: the reasoning, the treatments
/// with real prices and durations, the salons and artists to book them with,
/// any package that bundles them, bookable times that go straight into the
/// booking flow, and the maintenance advice that keeps the result alive.
///
/// While it works, the screen shimmers rather than spins — a plan composing
/// itself, not a progress bar. Every exchange is persisted into the user's
/// assistant conversation, so the thread is there next time.
///
/// ```swift
/// NavigationStack { BeautyAssistantView() }
/// ```
public struct BeautyAssistantView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = AssistantModel()

    /// Identifier of the anchor pinned to the bottom of the thread.
    private static let bottomAnchor = "prv.assistant.bottom"

    /// Creates the assistant. All dependencies come from the environment;
    /// the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        content
            .background { canvas }
            .navigationTitle("Beauty Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .task(id: session.currentUser?.id) {
                await model.load(for: session.currentUser, using: deps)
            }
            .prvToast($model.toast)
    }

    /// A whisper of brand gradient behind the canvas, so the assistant reads
    /// as a distinct place in the app.
    private var canvas: some View {
        ZStack {
            Color.prv.canvas
            LinearGradient(
                colors: [Color.prv.accent.opacity(0.16), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            loadingState
        case .failed(let message):
            ScrollView {
                ChatErrorCard(message: message) {
                    Task { await model.load(for: session.currentUser, using: deps) }
                }
                .padding(PRVSpacing.md)
            }
        case .loaded:
            thread
        }
    }

    private var loadingState: some View {
        VStack(spacing: PRVSpacing.lg) {
            AssistantHeroMark()
            PRVSkeleton(width: 220, height: 24)
            PRVSkeleton(width: 280, height: 14)
            PRVSkeleton(width: 240, height: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PRVSpacing.xl)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PRVSpacing.sm) {
                    if !model.hasThread && !model.isThinking {
                        heroPrompt
                            .padding(.top, PRVSpacing.xl)
                    }

                    ForEach(model.timeline) { item in
                        row(for: item)
                    }

                    if model.isThinking {
                        AssistantThinkingCard(prompt: model.pendingPrompt ?? "your look")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let errorMessage = model.errorMessage {
                        ChatErrorCard(message: errorMessage) {
                            guard let user = session.currentUser else { return }
                            Task { await model.retryFailedPrompt(as: user, using: deps) }
                        }
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
            .prvAnimation(PRVMotion.gentle, value: model.isThinking)
            .onChange(of: model.timeline.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: model.isThinking) { _, _ in scrollToBottom(proxy) }
        }
    }

    // MARK: - Hero

    private var heroPrompt: some View {
        VStack(spacing: PRVSpacing.lg) {
            AssistantHeroMark()

            VStack(spacing: PRVSpacing.xs) {
                Text("What are we creating?")
                    .prvStyle(.largeTitle)
                    .multilineTextAlignment(.center)
                Text("Tell me the goal — an occasion, a look, or a problem — and I'll plan the treatments, the salon, the artist, and the timing.")
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PRVSpacing.sm)

            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(AssistantModel.openingSuggestions, id: \.self) { suggestion in
                    PRVChip(suggestion, systemImage: "sparkle") {
                        ask(suggestion)
                    }
                    .accessibilityHint("Asks the assistant about this")
                }
            }
        }
        .padding(.bottom, PRVSpacing.md)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
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

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        PRVBottomBar {
            if session.currentUser == nil {
                Text("Sign in to ask your Beauty Assistant.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity)
            } else {
                AssistantComposer(model: model, onIntent: handle)
            }
        }
    }

    // MARK: - Bubble wiring

    private func messageContext(for message: ChatMessage) -> MessageContext {
        let isMine = session.currentUser.map { message.senderID == $0.id } ?? false

        var plan: AssistantPlan?
        if case .recommendation(let recommendation) = message.content {
            plan = model.plans[recommendation.id]
        }

        return MessageContext(
            isMine: isMine,
            senderName: isMine ? (session.currentUser?.firstName ?? "You") : "Beauty Assistant",
            senderAvatarURL: isMine ? session.currentUser?.avatarURL : nil,
            salonID: nil,
            service: nil,
            plan: plan
        )
    }

    private var messageActions: MessageActions {
        MessageActions(
            openMedia: { _ in },
            retry: { message in
                Task { await model.retryMessage(message, using: deps) }
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

    private func handle(_ intent: ComposerIntent) {
        guard let user = session.currentUser else { return }
        switch intent {
        case .send:
            Task { await model.submitDraft(as: user, using: deps) }
        case .quickReply(let text):
            Task { await model.ask(text, as: user, using: deps) }
        case .photoPicked, .videoPicked, .requestAppointment:
            // The assistant composer offers no attachments.
            break
        }
    }

    private func ask(_ prompt: String) {
        guard let user = session.currentUser else { return }
        PRVHaptics.impact()
        Task { await model.ask(prompt, as: user, using: deps) }
    }

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

// MARK: - Supporting views

/// The assistant's identity mark: a breathing gradient orb with a sparkle.
struct AssistantHeroMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isBreathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.prv.accentGradient)
                .frame(width: 92, height: 92)
                .blur(radius: 26)
                .opacity(isBreathing ? 0.55 : 0.28)

            Circle()
                .fill(Color.prv.accentGradient)
                .frame(width: 76, height: 76)

            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.prv.textOnAccent)
        }
        .scaleEffect(isBreathing ? 1.03 : 0.97)
        .animation(breathing, value: isBreathing)
        .onAppear { isBreathing = true }
        .accessibilityHidden(true)
    }

    private var breathing: Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
    }
}

/// The assistant's composer: no attachments, follow-up suggestions instead of
/// quick replies, and a send button that waits while a plan composes.
private struct AssistantComposer: View {
    @Bindable var model: AssistantModel
    let onIntent: (ComposerIntent) -> Void

    var body: some View {
        MessageComposer(
            draft: $model.draft,
            quickReplies: model.composerSuggestions,
            placeholder: "Ask your Beauty Assistant…",
            attachmentsEnabled: false,
            isSending: model.isThinking,
            onIntent: onIntent
        )
    }
}

// MARK: - Previews

#Preview("Beauty Assistant — Hero") {
    NavigationStack {
        BeautyAssistantView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .chat))
}

#Preview("Beauty Assistant — Dark") {
    NavigationStack {
        BeautyAssistantView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .chat))
    .preferredColorScheme(.dark)
}

#Preview("Beauty Assistant — Signed Out") {
    NavigationStack {
        BeautyAssistantView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .chat))
}
