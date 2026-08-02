import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Writes a campaign.
///
/// Name, kind, channels, and copy — with a live character count against the
/// limit the selected channels impose, and a Lock Screen mock that updates as
/// the copy is typed so the message is written against its real shape. An
/// optional coupon can be attached, and the send can be scheduled.
struct CampaignComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let salonName: String
    let coupons: [Coupon]
    let isSaving: Bool
    /// Persists the draft. Returns `true` when the sheet should close.
    let save: @MainActor (CampaignDraft) async -> Bool

    @State private var draft: CampaignDraft

    /// Creates the composer over a draft — empty, prefilled from a suggestion,
    /// or loaded from an existing campaign.
    init(
        draft: CampaignDraft,
        salonName: String,
        coupons: [Coupon],
        isSaving: Bool,
        save: @escaping @MainActor (CampaignDraft) async -> Bool
    ) {
        self.salonName = salonName
        self.coupons = coupons
        self.isSaving = isSaving
        self.save = save
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    basicsCard
                    channelsCard
                    messageCard
                    LockScreenPushPreview(salonName: salonName, message: draft.message)
                    couponCard
                    scheduleCard
                }
                .padding(PRVSpacing.md)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(draft.isEditing ? "Edit Campaign" : "New Campaign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .prvBottomBar {
                Button {
                    submit()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(draft.isScheduled ? "Schedule Campaign" : "Save Draft")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(!draft.isValid || isSaving)
                .accessibilityLabel(draft.isScheduled ? "Schedule this campaign" : "Save this campaign as a draft")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .prvAnimation(PRVMotion.quick, value: draft.channels)
    }

    // MARK: Basics

    private var basicsCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text("Name")
                        .prvStyle(.footnote)
                    TextField("Autumn Gloss Refresh", text: $draft.name)
                        .font(.body)
                        .foregroundStyle(Color.prv.textPrimary)
                        .accessibilityLabel("Campaign name")
                }

                Divider()

                Picker("Kind", selection: $draft.kind) {
                    ForEach(Campaign.Kind.allCases, id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.prv.accent)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Campaign kind")
            }
        }
    }

    // MARK: Channels

    private var channelsCard: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Channels", subtitle: "Where this campaign goes out")

            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(Campaign.Channel.allCases, id: \.self) { channel in
                    PRVChip(
                        channel.displayName,
                        systemImage: channel.symbolName,
                        isSelected: draft.channels.contains(channel)
                    ) {
                        draft.toggle(channel)
                    }
                    .accessibilityAddTraits(draft.channels.contains(channel) ? [.isSelected] : [])
                }
            }

            if draft.channels.isEmpty {
                OperationsFootnote("Pick at least one channel.", systemImage: "exclamationmark.triangle")
            } else if draft.channels.contains(.sms) {
                OperationsFootnote("SMS is billed per 160-character segment, so the limit tightens with SMS selected.")
            }
        }
    }

    // MARK: Message

    private var messageCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                HStack {
                    Text("Message")
                        .prvStyle(.footnote)
                    Spacer(minLength: PRVSpacing.xs)
                    Text("\(draft.characterCount) / \(draft.characterLimit)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(draft.isOverLimit ? Color.prv.danger : Color.prv.textSecondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityLabel(
                            draft.isOverLimit
                                ? "\(draft.characterCount) characters, over the \(draft.characterLimit) limit"
                                : "\(draft.characterCount) of \(draft.characterLimit) characters used"
                        )
                }

                TextField(
                    "Write the message your clients will read…",
                    text: $draft.message,
                    axis: .vertical
                )
                .lineLimit(4...8)
                .font(.body)
                .foregroundStyle(Color.prv.textPrimary)
                .accessibilityLabel("Campaign message")

                if draft.isOverLimit {
                    OperationsFootnote(
                        "Trim \(draft.characterCount - draft.characterLimit) characters so nothing gets cut off.",
                        systemImage: "scissors"
                    )
                }
            }
        }
        .prvAnimation(PRVMotion.quick, value: draft.isOverLimit)
    }

    // MARK: Coupon

    private var couponCard: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Coupon", subtitle: "Optional discount to attach")

            PRVGlassCard {
                if coupons.isEmpty {
                    Text("No coupons yet. Create one on the Coupons tab and it becomes attachable here.")
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Coupon", selection: $draft.couponID) {
                        Text("None").tag(Coupon.ID?.none)
                        ForEach(coupons) { coupon in
                            Text("\(coupon.code) · \(coupon.discountSummary)")
                                .tag(Coupon.ID?.some(coupon.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.prv.accent)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Coupon to attach to this campaign")
                }
            }
        }
    }

    // MARK: Schedule

    private var scheduleCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                Toggle("Schedule the send", isOn: $draft.isScheduled)
                    .font(.subheadline.weight(.medium))
                    .tint(Color.prv.accent)
                    .accessibilityHint("Off keeps the campaign as a draft")

                if draft.isScheduled {
                    Divider()
                    DatePicker(
                        "Goes out",
                        selection: $draft.scheduledAt,
                        in: Date.now...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .tint(Color.prv.accent)
                    .font(.subheadline.weight(.medium))
                    .accessibilityLabel("Send date and time")
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: draft.isScheduled)
    }

    // MARK: Actions

    private func submit() {
        guard draft.isValid, !isSaving else { return }
        PRVHaptics.impact()
        Task {
            if await save(draft) { dismiss() }
        }
    }
}

// MARK: - Previews

#Preview("Composer") {
    CampaignComposerSheet(
        draft: CampaignDraft(
            name: "Tuesday Treat",
            kind: .promotion,
            channels: [.push, .email],
            message: "Tuesdays are calm at Maison Lumière. Book any treatment this Tuesday and take 15% off.",
            isScheduled: true
        ),
        salonName: PreviewData.salonLumiere.name,
        coupons: [
            Coupon(
                salonID: PreviewData.salonLumiere.id,
                code: "WELCOME10",
                discount: .percent(10)
            ),
        ],
        isSaving: false,
        save: { _ in true }
    )
}
