import PhotosUI
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Something the user asked the composer to do. The composer never talks to
/// repositories itself — the hosting screen turns intents into work.
enum ComposerIntent {
    /// Send whatever is currently in the bound draft.
    case send
    /// Send a one-tap reply without touching the draft.
    case quickReply(String)
    /// A photo was picked from the library.
    case photoPicked(PhotosPickerItem)
    /// A video was picked from the library.
    case videoPicked(PhotosPickerItem)
    /// Open the structured appointment-request sheet.
    case requestAppointment
}

/// The Liquid Glass input bar: an attachment menu, a growing text field, a
/// gradient send button, and — while the field is empty — a row of one-tap
/// quick replies.
///
/// Attach it with `.prvBottomBar { MessageComposer(…) }` so it floats above
/// the transcript and rises with the keyboard.
struct MessageComposer: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The text being composed.
    @Binding var draft: String
    /// One-tap replies offered while the field is empty.
    var quickReplies: [String] = []
    /// Placeholder shown in the empty field.
    var placeholder: String = "Message"
    /// Whether the attachment menu is offered at all.
    var attachmentsEnabled: Bool = true
    /// Whether the attachment menu offers a structured appointment request.
    var canRequestAppointment: Bool = false
    /// Whether a message is currently in flight.
    var isSending: Bool = false
    /// Raised for every composer action.
    let onIntent: (ComposerIntent) -> Void

    @FocusState private var isFocused: Bool
    @State private var isPhotoPickerPresented = false
    @State private var isVideoPickerPresented = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var videoSelection: PhotosPickerItem?

    private var trimmedDraft: String { draft.trimmed }
    private var canSend: Bool { !trimmedDraft.isEmpty && !isSending }
    private var showsQuickReplies: Bool { !quickReplies.isEmpty && trimmedDraft.isEmpty }

    var body: some View {
        VStack(spacing: PRVSpacing.xs) {
            if showsQuickReplies {
                quickReplyRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .bottom, spacing: PRVSpacing.xs) {
                if attachmentsEnabled {
                    attachmentMenu
                }
                inputField
                sendButton
            }
        }
        .prvAnimation(PRVMotion.quick, value: showsQuickReplies)
        .prvAnimation(PRVMotion.quick, value: canSend)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelection,
            matching: .images
        )
        .photosPicker(
            isPresented: $isVideoPickerPresented,
            selection: $videoSelection,
            matching: .videos
        )
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            photoSelection = nil
            onIntent(.photoPicked(item))
        }
        .onChange(of: videoSelection) { _, item in
            guard let item else { return }
            videoSelection = nil
            onIntent(.videoPicked(item))
        }
    }

    // MARK: - Quick replies

    private var quickReplyRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PRVSpacing.xs) {
                ForEach(quickReplies, id: \.self) { reply in
                    PRVChip(reply) {
                        onIntent(.quickReply(reply))
                    }
                    .accessibilityHint("Sends this reply")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Quick replies")
    }

    // MARK: - Controls

    private var attachmentMenu: some View {
        Menu {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle.angled")
            }

            Button {
                isVideoPickerPresented = true
            } label: {
                Label("Video", systemImage: "video.fill")
            }

            if canRequestAppointment {
                Divider()
                Button {
                    onIntent(.requestAppointment)
                } label: {
                    Label("Request an Appointment", systemImage: "calendar.badge.plus")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .frame(width: 34, height: 34)
                .prvGlassEffect(interactive: true)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Add an attachment")
        .accessibilityHint("Photos, videos, or an appointment request")
    }

    private var inputField: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .font(.body)
            .foregroundStyle(Color.prv.textPrimary)
            .lineLimit(1...5)
            .focused($isFocused)
            .textInputAutocapitalization(.sentences)
            .padding(.vertical, PRVSpacing.xs + 1)
            .padding(.horizontal, PRVSpacing.sm)
            .background {
                if reduceTransparency {
                    PRVRadius.shape(PRVRadius.md).fill(Color.prv.surface)
                } else {
                    PRVRadius.shape(PRVRadius.md).fill(.ultraThinMaterial)
                }
            }
            .overlay {
                PRVRadius.shape(PRVRadius.md).strokeBorder(
                    isFocused ? Color.prv.accent.opacity(0.5) : .white.opacity(0.12),
                    lineWidth: isFocused ? 1 : 0.5
                )
            }
            .prvAnimation(PRVMotion.quick, value: isFocused)
            .accessibilityLabel(placeholder)
    }

    private var sendButton: some View {
        Button {
            guard canSend else { return }
            PRVHaptics.impact()
            onIntent(.send)
        } label: {
            Image(systemName: isSending ? "ellipsis" : "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(Color.prv.textOnAccent)
                .frame(width: 34, height: 34)
                .background(sendButtonFill, in: Circle())
                .scaleEffect(canSend ? 1 : 0.92)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(isSending ? "Sending message" : "Send message")
    }

    private var sendButtonFill: AnyShapeStyle {
        canSend
            ? AnyShapeStyle(Color.prv.accentGradient)
            : AnyShapeStyle(Color.prv.textSecondary.opacity(0.35))
    }
}

#Preview("Composer — Light") {
    @Previewable @State var draft = ""

    VStack {
        Spacer()
        MessageComposer(
            draft: $draft,
            quickReplies: ["Running 5 min late", "Can I reschedule?", "Thank you!"],
            canRequestAppointment: true,
            onIntent: { _ in }
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}

#Preview("Composer — Dark") {
    @Previewable @State var draft = "See you Thursday"

    VStack {
        Spacer()
        MessageComposer(
            draft: $draft,
            quickReplies: ["Running 5 min late", "Can I reschedule?", "Thank you!"],
            placeholder: "Ask your assistant…",
            attachmentsEnabled: false,
            onIntent: { _ in }
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
