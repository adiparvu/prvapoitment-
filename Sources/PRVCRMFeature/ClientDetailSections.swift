import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Status styling

extension AppointmentStatus {
    /// Tint used by CRM visit rows.
    var crmTint: Color {
        switch self {
        case .pendingConfirmation: Color.prv.warning
        case .confirmed: Color.prv.accent
        case .checkedIn: Color.prv.gold
        case .inProgress: Color.prv.success
        case .completed: Color.prv.success
        case .cancelledByClient, .cancelledBySalon, .noShow: Color.prv.danger
        }
    }
}

// MARK: - Header

/// Client identity plus the three ways to reach them.
///
/// Contact buttons open the system handlers (`tel:`, `sms:`, `mailto:`) and
/// simply do not appear when the salon has no number or address on file.
struct ClientHeaderCard: View {
    @Environment(\.openURL) private var openURL

    let client: ClientRecord

    private var tier: ClientTier { ClientTier.tier(for: client) }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            HStack(spacing: PRVSpacing.md) {
                PRVAvatar(name: client.fullName, imageURL: client.avatarURL, size: .large)

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text(client.fullName)
                        .prvStyle(.title2)
                        .lineLimit(2)

                    HStack(spacing: PRVSpacing.xs) {
                        PRVBadge(tier.title, tint: tier.tint)
                        Text("Client since \(CRMFormat.day(client.createdAt))")
                            .prvStyle(.caption)
                    }
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if !contactActions.isEmpty {
                HStack(spacing: PRVSpacing.xs) {
                    ForEach(contactActions) { action in
                        contactButton(action)
                    }
                }
            }
        }
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
    }

    /// One tappable way to reach the client.
    private struct ContactAction: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let url: URL
    }

    private var contactActions: [ContactAction] {
        var actions: [ContactAction] = []
        if let phone = client.phone?.trimmed, !phone.isEmpty {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:\(digits)") {
                actions.append(ContactAction(id: "call", title: "Call", systemImage: "phone.fill", url: url))
            }
            if let url = URL(string: "sms:\(digits)") {
                actions.append(ContactAction(id: "message", title: "Message", systemImage: "message.fill", url: url))
            }
        }
        if let email = client.email?.trimmed, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
            actions.append(ContactAction(id: "email", title: "Email", systemImage: "envelope.fill", url: url))
        }
        return actions
    }

    private func contactButton(_ action: ContactAction) -> some View {
        Button {
            PRVHaptics.tap()
            openURL(action.url)
        } label: {
            HStack(spacing: PRVSpacing.xxs) {
                Image(systemName: action.systemImage)
                    .font(.caption.weight(.semibold))
                Text(action.title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Color.prv.accent)
            .padding(.vertical, PRVSpacing.xs)
            .frame(maxWidth: .infinity)
            .background(Color.prv.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action.title) \(client.firstName)")
    }
}

// MARK: - Stats

/// Lifetime numbers for one client.
struct ClientStatsRow: View {
    let client: ClientRecord
    let averageSpend: Money

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 148), spacing: PRVSpacing.sm)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: PRVSpacing.sm) {
            PRVStatTile(label: "Visits", value: "\(client.totalVisits)")
                .accessibilityLabel("\(client.totalVisits) visits")

            PRVStatTile(label: "Lifetime spend", value: client.totalSpend.formatted)
                .accessibilityLabel("Lifetime spend \(client.totalSpend.formatted)")

            PRVStatTile(label: "Average visit", value: averageSpend.formatted)
                .accessibilityLabel("Average spend per visit \(averageSpend.formatted)")

            PRVStatTile(label: "Last visit", value: CRMFormat.lastVisit(client.lastVisitAt))
                .accessibilityLabel("Last visit \(CRMFormat.lastVisit(client.lastVisitAt))")
        }
    }
}

// MARK: - Beauty profile

/// Skin and hair type, allergies, and standing preferences.
///
/// Allergies get danger styling and their own VoiceOver announcement: they are
/// the one thing on this screen that must never be skimmed past.
struct BeautyProfileCard: View {
    let client: ClientRecord

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            if !client.allergies.isEmpty {
                allergyBanner
            }

            if client.skinType != nil || client.hairType != nil || client.birthday != nil {
                VStack(spacing: PRVSpacing.xs) {
                    if let skinType = client.skinType {
                        attribute("Skin", value: skinType, systemImage: "drop.fill")
                    }
                    if let hairType = client.hairType {
                        attribute("Hair", value: hairType, systemImage: "comb.fill")
                    }
                    if let birthday = client.birthday {
                        attribute("Birthday", value: CRMFormat.birthday(birthday), systemImage: "gift.fill")
                    }
                }
            }

            if !client.preferences.isEmpty {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Preferences")
                        .prvStyle(.footnote)
                    PRVFlowLayout(spacing: PRVSpacing.xs) {
                        ForEach(client.preferences, id: \.self) { preference in
                            PRVTag(preference, systemImage: "heart.fill", tint: Color.prv.accent)
                        }
                    }
                }
            }

            if isEmpty {
                Text("No beauty profile yet. Add skin and hair type so every stylist starts from the same page.")
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard()
    }

    private var isEmpty: Bool {
        client.allergies.isEmpty
            && client.preferences.isEmpty
            && client.skinType == nil
            && client.hairType == nil
            && client.birthday == nil
    }

    private var allergyBanner: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.prv.danger)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text("Allergies")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.prv.danger)
                Text(client.allergies.joined(separator: " · "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.danger.opacity(0.10), in: PRVRadius.shape(PRVRadius.md))
        .overlay {
            PRVRadius.shape(PRVRadius.md)
                .strokeBorder(Color.prv.danger.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warning. Allergies: \(client.allergies.joined(separator: ", "))")
    }

    private func attribute(_ label: String, value: String, systemImage: String) -> some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(Color.prv.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label)
                .prvStyle(.footnote)
            Spacer(minLength: PRVSpacing.xs)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.prv.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Colour formulas

/// The colourist's record: every formula ever used, newest first, each with a
/// swatch so the history reads at a glance.
struct ColorFormulaTimeline: View {
    let formulas: [ClientNote]

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            if formulas.isEmpty {
                Text("No colour formulas recorded yet. Add one from the Notes tab after the next service.")
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(formulas.enumerated()), id: \.element.id) { index, formula in
                    row(formula, index: index, isLast: index == formulas.count - 1)
                }
            }
        }
        .prvGlassCard()
    }

    private func row(_ formula: ClientNote, index: Int, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            VStack(spacing: 0) {
                swatch(for: index)
                if !isLast {
                    Rectangle()
                        .fill(Color.prv.separator.opacity(0.5))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.top, PRVSpacing.xxs)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(CRMFormat.day(formula.createdAt))
                    .prvStyle(.caption)
                Text(formula.text)
                    .font(.subheadline.weight(.medium))
                    .monospaced()
                    .foregroundStyle(Color.prv.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : PRVSpacing.sm)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Formula from \(CRMFormat.day(formula.createdAt)): \(formula.text)")
    }

    /// A tinted swatch; the newest formula is the most saturated so the current
    /// colour is obvious at a glance.
    private func swatch(for index: Int) -> some View {
        let strength = max(0.35, 1 - Double(index) * 0.18)
        return PRVRadius.shape(PRVRadius.sm)
            .fill(Color.prv.accentGradient)
            .opacity(strength)
            .frame(width: 28, height: 28)
            .overlay {
                PRVRadius.shape(PRVRadius.sm)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
    }
}

// MARK: - Notes

/// A single note in the client's file.
struct ClientNoteCard: View {
    let note: ClientNote

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(spacing: PRVSpacing.xs) {
                Image(systemName: note.kind.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(note.kind.tint)
                Text(note.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(note.kind.tint)
                Spacer(minLength: PRVSpacing.xxs)
                Text(CRMFormat.day(note.createdAt))
                    .prvStyle(.caption)
            }

            Text(note.text)
                .font(.subheadline)
                .foregroundStyle(Color.prv.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(note.kind.title), \(CRMFormat.day(note.createdAt)). \(note.text)")
    }
}

// MARK: - Visits

/// One appointment in the client's history.
struct ClientVisitRow: View {
    let appointment: Appointment

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appointment.start.map(CRMFormat.dayTime) ?? "Date pending")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(services)
                    .prvStyle(.footnote)
                    .lineLimit(2)
                if let professional = appointment.items.compactMap(\.professionalName).first {
                    Text(professional)
                        .prvStyle(.caption)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            VStack(alignment: .trailing, spacing: PRVSpacing.xxs) {
                Text(appointment.totalPrice.formatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
                Text(appointment.status.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appointment.status.crmTint)
                    .padding(.vertical, 2)
                    .padding(.horizontal, PRVSpacing.xs)
                    .background(appointment.status.crmTint.opacity(0.14), in: Capsule())
            }
        }
        .prvGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(appointment.start.map(CRMFormat.dayTime) ?? "Date pending"), \(services), \(appointment.totalPrice.formatted), \(appointment.status.displayName)"
        )
    }

    private var services: String {
        let names = appointment.items.map(\.serviceName)
        return names.isEmpty ? "Appointment" : names.joined(separator: ", ")
    }
}

// MARK: - Consent

/// A signed consent document on file.
struct ConsentFormRow: View {
    let form: ConsentForm
    let sign: () -> Void

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: form.signedAt == nil ? "doc.text" : "checkmark.seal.fill")
                .font(.body)
                .foregroundStyle(form.signedAt == nil ? Color.prv.warning : Color.prv.success)
                .frame(width: 36, height: 36)
                .background(
                    (form.signedAt == nil ? Color.prv.warning : Color.prv.success).opacity(0.12),
                    in: PRVRadius.shape(PRVRadius.sm)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(form.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            if form.signedAt == nil {
                Button("Sign") {
                    PRVHaptics.tap()
                    sign()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("Capture signature for \(form.title)")
            } else if let url = form.documentURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                }
                .accessibilityLabel("Share \(form.title)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        guard let signedAt = form.signedAt else {
            return "Version \(form.version) · awaiting signature"
        }
        return "Version \(form.version) · signed \(CRMFormat.day(signedAt))"
    }
}

/// A standard document the client has not signed yet.
struct ConsentTemplateRow: View {
    let template: ConsentTemplate
    let sign: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            sign()
        } label: {
            HStack(spacing: PRVSpacing.sm) {
                PRVListRowIcon(systemImage: "signature")

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                    Text(template.details)
                        .prvStyle(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: PRVSpacing.xs)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture signature for \(template.title), version \(template.version)")
        .accessibilityHint(template.details)
    }
}

// MARK: - Add note

/// Captures a new note with its kind — the same sheet whether the stylist is
/// recording a colour formula, a treatment, or a plain observation.
struct AddNoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let clientName: String
    /// Persists the note; the sheet dismisses once it returns.
    let save: @MainActor (ClientNote.Kind, String) async -> Void

    @State private var kind: ClientNote.Kind = .general
    @State private var text = ""
    @State private var isSaving = false
    @FocusState private var isEditorFocused: Bool

    private var kinds: [ClientNote.Kind] { [.general, .colorFormula, .treatment] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    PRVSegmentedGlassControl(selection: $kind, options: kinds, title: \.title)

                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        Text(prompt)
                            .prvStyle(.footnote)

                        TextEditor(text: $text)
                            .focused($isEditorFocused)
                            .font(.body)
                            .monospaced(kind == .colorFormula)
                            .foregroundStyle(Color.prv.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 180)
                            .accessibilityLabel("Note text")
                    }
                    .prvGlassCard()
                }
                .padding(PRVSpacing.lg)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Note for \(clientName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .fontWeight(.semibold)
                        .disabled(text.isBlank || isSaving)
                }
            }
            .task { isEditorFocused = true }
        }
    }

    private var prompt: String {
        switch kind {
        case .colorFormula: "Formula, developer, timing — exactly as mixed."
        case .treatment: "What was done, what to watch next time."
        case .photo: "Describe the look you photographed."
        case .general: "Anything the next stylist should know."
        }
    }

    private func submit() {
        guard !text.isBlank, !isSaving else { return }
        isSaving = true
        let kind = kind
        let text = text
        Task {
            await save(kind, text)
            isSaving = false
            dismiss()
        }
    }
}
