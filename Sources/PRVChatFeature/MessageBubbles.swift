import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Bubble inputs

/// Everything a bubble needs that does not live on the message itself.
struct MessageContext {
    /// Whether the message was sent by the signed-in user.
    var isMine: Bool
    /// Name of the message's author, shown at the head of a run.
    var senderName: String
    /// Author's avatar, shown at the tail of a run.
    var senderAvatarURL: URL?
    /// Salon behind the conversation — the fallback booking target.
    var salonID: Salon.ID?
    /// Service behind an `appointmentRequest`, once resolved.
    var service: SalonService?
    /// Resolved card for a `recommendation`, once resolved.
    var plan: AssistantPlan?

    init(
        isMine: Bool,
        senderName: String,
        senderAvatarURL: URL? = nil,
        salonID: Salon.ID? = nil,
        service: SalonService? = nil,
        plan: AssistantPlan? = nil
    ) {
        self.isMine = isMine
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.salonID = salonID
        self.service = service
        self.plan = plan
    }
}

/// Navigation and mutation callbacks a bubble can raise. Bubbles never touch
/// the router or the repositories themselves.
struct MessageActions {
    /// Opens media full screen.
    var openMedia: (ChatMediaPreview) -> Void = { _ in }
    /// Re-sends a failed message.
    var retry: (ChatMessage) -> Void = { _ in }
    /// Starts the booking flow for a salon and a service selection.
    var book: (Salon.ID, [SalonService.ID]) -> Void = { _, _ in }
    /// Opens a salon profile.
    var openSalon: (Salon.ID) -> Void = { _ in }
    /// Opens a professional profile.
    var openProfessional: (Professional.ID) -> Void = { _ in }
    /// Opens the packages catalogue, optionally scoped to a salon.
    var openPackages: (Salon.ID?) -> Void = { _ in }
}

// MARK: - Transcript rows

/// A day separator floating above the messages it introduces.
struct ChatDayHeaderRow: View {
    let header: ChatDayHeader

    var body: some View {
        Text(ChatFormat.dayHeader(header.date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.prv.textSecondary)
            .padding(.vertical, PRVSpacing.xxs)
            .padding(.horizontal, PRVSpacing.sm)
            .prvGlassEffect()
            .frame(maxWidth: .infinity)
            .padding(.vertical, PRVSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One rendered message: a glass bubble for conversational content, or a
/// full-width card for structured content (appointment requests, assistant
/// recommendations).
struct MessageRow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let entry: ChatTimelineMessage
    let context: MessageContext
    let actions: MessageActions

    /// Widest a media bubble grows, so photos never dominate the transcript.
    private static let mediaWidth: CGFloat = 240
    /// Minimum breathing room on the opposite side of a bubble.
    private static let gutter: CGFloat = 56

    private var message: ChatMessage { entry.message }
    private var isMine: Bool { context.isMine }

    var body: some View {
        if ChatTimeline.isStructured(message) {
            structuredRow
        } else {
            bubbleRow
        }
    }

    // MARK: Structured content

    private var structuredRow: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: PRVSpacing.xxs) {
            structuredCard
            footnote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PRVSpacing.xxs)
    }

    @ViewBuilder
    private var structuredCard: some View {
        switch message.content {
        case .appointmentRequest(let serviceID, let preferredDate):
            AppointmentRequestCard(
                serviceID: serviceID,
                preferredDate: preferredDate,
                service: context.service,
                fallbackSalonID: context.salonID,
                isMine: isMine,
                onChooseTime: actions.book
            )
        case .recommendation(let recommendation):
            AssistantRecommendationCard(
                plan: context.plan ?? AssistantPlan(recommendation: recommendation),
                isResolving: context.plan == nil,
                actions: actions
            )
        case .text, .photo, .video, .voice:
            EmptyView()
        }
    }

    // MARK: Conversational content

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: PRVSpacing.xs) {
            if isMine {
                Spacer(minLength: Self.gutter)
            } else {
                avatarSlot
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: PRVSpacing.xxs) {
                if entry.isRunHead, !isMine {
                    Text(context.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.prv.textSecondary)
                        .padding(.horizontal, PRVSpacing.xxs)
                        .lineLimit(1)
                }

                bubble

                footnote
            }

            if !isMine {
                Spacer(minLength: Self.gutter)
            }
        }
    }

    /// Reserves the avatar column so bubbles in a run stay aligned.
    @ViewBuilder
    private var avatarSlot: some View {
        if entry.isRunTail {
            senderAvatar
        } else {
            Color.clear
                .frame(width: 28, height: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var senderAvatar: some View {
        if message.isFromAssistant {
            ZStack {
                Circle().fill(Color.prv.accentGradient)
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.prv.textOnAccent)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
        } else {
            PRVAvatar(name: context.senderName, imageURL: context.senderAvatarURL, size: .small)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.content {
        case .text(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(isMine ? Color.prv.textOnAccent : Color.prv.textPrimary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.vertical, PRVSpacing.xs + 2)
                .padding(.horizontal, PRVSpacing.sm + 2)
                .modifier(BubbleChrome(shape: bubbleShape, isMine: isMine))

        case .photo(let url, let caption):
            mediaBubble(url: url, caption: caption, kind: .photo)

        case .video(let url, let caption):
            mediaBubble(url: url, caption: caption, kind: .video)

        case .voice(let url, let seconds):
            VoiceNoteContent(
                url: url,
                durationSeconds: seconds,
                seed: message.id.description,
                isMine: isMine
            )
            .modifier(BubbleChrome(shape: bubbleShape, isMine: isMine))

        case .appointmentRequest, .recommendation:
            EmptyView()
        }
    }

    /// Photo and video bubbles share their frame, caption strip, and tap
    /// behaviour; only the play badge differs.
    private func mediaBubble(
        url: URL,
        caption: String?,
        kind: ChatMediaPreview.Kind
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                PRVHaptics.tap()
                actions.openMedia(ChatMediaPreview(url: url, kind: kind, caption: caption))
            } label: {
                PRVAsyncImage(url: url)
                    .frame(width: Self.mediaWidth, height: Self.mediaWidth * 0.72)
                    .clipped()
                    .overlay {
                        if kind == .video { playBadge }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(kind == .video ? "Video message" : "Photo message")
            .accessibilityHint(kind == .video ? "Opens the video full screen" : "Opens the photo full screen")

            if let caption, !caption.isBlank {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(isMine ? Color.prv.textOnAccent : Color.prv.textPrimary)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, PRVSpacing.xs)
                    .padding(.horizontal, PRVSpacing.sm)
                    .frame(width: Self.mediaWidth, alignment: .leading)
            }
        }
        .modifier(BubbleChrome(shape: bubbleShape, isMine: isMine))
    }

    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(.black.opacity(0.35), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1) }
            .accessibilityHidden(true)
    }

    // MARK: Footnote

    @ViewBuilder
    private var footnote: some View {
        if entry.isRunTail {
            HStack(spacing: PRVSpacing.xxs) {
                Text(ChatFormat.clockTime(message.sentAt))
                    .prvStyle(.caption)
                    .monospacedDigit()
                if isMine {
                    DeliveryStateMark(state: message.deliveryState)
                }
            }
            .padding(.horizontal, PRVSpacing.xxs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(footnoteLabel)
        }

        if isMine, message.deliveryState == .failed {
            Button {
                PRVHaptics.tap()
                actions.retry(message)
            } label: {
                HStack(spacing: PRVSpacing.xxs) {
                    Image(systemName: "arrow.clockwise")
                    Text("Tap to retry")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.prv.danger)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, PRVSpacing.xxs)
            .accessibilityLabel("Message not sent. Tap to send it again")
        }
    }

    private var footnoteLabel: String {
        var text = ChatFormat.spokenTimestamp(message.sentAt)
        if isMine {
            text += ", \(DeliveryStateMark.description(message.deliveryState))"
        }
        return text
    }

    // MARK: Shape

    /// Rounded on three corners, tucked in on the tail corner of a run.
    private var bubbleShape: UnevenRoundedRectangle {
        let tail: CGFloat = PRVSpacing.xxs + 2
        return UnevenRoundedRectangle(
            topLeadingRadius: PRVRadius.lg,
            bottomLeadingRadius: (!isMine && entry.isRunTail) ? tail : PRVRadius.lg,
            bottomTrailingRadius: (isMine && entry.isRunTail) ? tail : PRVRadius.lg,
            topTrailingRadius: PRVRadius.lg,
            style: .continuous
        )
    }
}

/// The bubble's surface: the brand gradient for the signed-in user, Liquid
/// Glass for everyone else, with a Reduce Transparency fallback.
private struct BubbleChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let shape: UnevenRoundedRectangle
    let isMine: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isMine {
                    Color.prv.accentGradient
                } else if reduceTransparency {
                    Color.prv.surface
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    isMine ? .white.opacity(0.18) : .white.opacity(0.12),
                    lineWidth: 0.5
                )
            }
            .prvSoftShadow()
    }
}

// MARK: - Delivery state

/// The tick mark shown beneath the user's own messages.
struct DeliveryStateMark: View {
    let state: ChatMessage.DeliveryState

    var body: some View {
        Image(systemName: symbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch state {
        case .sending: "clock"
        case .sent: "checkmark"
        case .delivered: "checkmark.circle"
        case .read: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .sending, .sent, .delivered: Color.prv.textSecondary
        case .read: Color.prv.accent
        case .failed: Color.prv.danger
        }
    }

    /// Spoken form of a delivery state, folded into the footnote's label.
    static func description(_ state: ChatMessage.DeliveryState) -> String {
        switch state {
        case .sending: "sending"
        case .sent: "sent"
        case .delivered: "delivered"
        case .read: "read"
        case .failed: "not sent"
        }
    }
}

// MARK: - Typing indicator

/// Three breathing dots in a glass bubble, shown while a reply is arriving.
/// Reduce Motion renders them still rather than removing the affordance.
struct TypingIndicatorBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Who is typing, used for the VoiceOver announcement.
    let name: String

    @State private var isBreathing = false

    var body: some View {
        HStack(alignment: .bottom, spacing: PRVSpacing.xs) {
            Color.clear
                .frame(width: 28, height: 1)
                .accessibilityHidden(true)

            HStack(spacing: PRVSpacing.xxs + 1) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.prv.textSecondary.opacity(0.65))
                        .frame(width: 7, height: 7)
                        .scaleEffect(isBreathing ? 1 : 0.55)
                        .opacity(isBreathing ? 1 : 0.45)
                        .animation(animation(delayedBy: index), value: isBreathing)
                }
            }
            .padding(.vertical, PRVSpacing.sm)
            .padding(.horizontal, PRVSpacing.md)
            .background {
                if reduceTransparency {
                    Capsule().fill(Color.prv.surface)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }

            Spacer(minLength: 0)
        }
        .onAppear { isBreathing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is typing")
    }

    private func animation(delayedBy index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * 0.18)
    }
}

// MARK: - Previews

/// Deterministic fixtures for the bubble previews.
enum BubblePreviewFixtures {
    static let conversationID = Conversation.ID("00000000-0000-0000-0007-000000000001")

    static let theirText = entry(
        ChatMessage(
            conversationID: conversationID,
            senderID: PreviewData.owner.id,
            content: .text("Bonjour Sofia! We have you down for Thursday at 14:00 with Amélie."),
            deliveryState: .delivered,
            sentAt: Date.now.addingTimeInterval(-900)
        )
    )

    static let myText = entry(
        ChatMessage(
            conversationID: conversationID,
            senderID: PreviewData.client.id,
            content: .text("Perfect, thank you!"),
            deliveryState: .read,
            sentAt: Date.now.addingTimeInterval(-600)
        )
    )

    static let myFailedVoice = entry(
        ChatMessage(
            conversationID: conversationID,
            senderID: PreviewData.client.id,
            content: .voice(URL(filePath: "/preview/note.m4a"), durationSeconds: 27),
            deliveryState: .failed,
            sentAt: Date.now.addingTimeInterval(-300)
        )
    )

    static let theirContext = MessageContext(
        isMine: false,
        senderName: PreviewData.salonLumiere.name,
        salonID: PreviewData.salonLumiere.id
    )

    static let myContext = MessageContext(
        isMine: true,
        senderName: PreviewData.client.fullName
    )

    private static func entry(_ message: ChatMessage) -> ChatTimelineMessage {
        ChatTimelineMessage(message: message, isRunHead: true, isRunTail: true)
    }
}

#Preview("Message Bubbles — Light") {
    ScrollView {
        VStack(spacing: PRVSpacing.xs) {
            ChatDayHeaderRow(header: ChatDayHeader(date: .now))
            MessageRow(
                entry: BubblePreviewFixtures.theirText,
                context: BubblePreviewFixtures.theirContext,
                actions: MessageActions()
            )
            MessageRow(
                entry: BubblePreviewFixtures.myText,
                context: BubblePreviewFixtures.myContext,
                actions: MessageActions()
            )
            MessageRow(
                entry: BubblePreviewFixtures.myFailedVoice,
                context: BubblePreviewFixtures.myContext,
                actions: MessageActions()
            )
            TypingIndicatorBubble(name: PreviewData.salonLumiere.name)
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}

#Preview("Message Bubbles — Dark") {
    ScrollView {
        VStack(spacing: PRVSpacing.xs) {
            ChatDayHeaderRow(header: ChatDayHeader(date: .now))
            MessageRow(
                entry: BubblePreviewFixtures.theirText,
                context: BubblePreviewFixtures.theirContext,
                actions: MessageActions()
            )
            MessageRow(
                entry: BubblePreviewFixtures.myText,
                context: BubblePreviewFixtures.myContext,
                actions: MessageActions()
            )
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
