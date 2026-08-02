import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Everything the salon knows about one client.
///
/// The header carries identity and one-tap contact actions; a beauty-profile
/// card puts allergies front and centre; a colour-formula timeline reads like a
/// colourist's notebook; and three tabs cover notes, visit history, and consent
/// documents (signed on-device with a `Canvas` signature pad). The overflow menu
/// holds the two GDPR obligations: a portable JSON export and an erasure
/// request.
public struct ClientDetailView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    @State private var model = ClientDetailModel()
    @State private var tab: ClientDetailTab = .notes
    @State private var isAddingNote = false
    @State private var signingTarget: SigningTarget?
    @State private var isConfirmingErasure = false

    private let clientID: ClientRecord.ID

    /// Creates the client record screen.
    /// - Parameter clientID: The CRM record to display.
    public init(clientID: ClientRecord.ID) {
        self.clientID = clientID
    }

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                switch model.phase {
                case .loading:
                    ClientDetailSkeleton()
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    if let client = model.client {
                        content(for: client)
                    }
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle(model.client?.firstName ?? "Client")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                privacyMenu
            }
        }
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .prvAnimation(PRVMotion.spring, value: tab)
        .refreshable { await refresh() }
        .task(id: clientID) { await refresh() }
        .sheet(isPresented: $isAddingNote) {
            AddNoteSheet(clientName: model.client?.firstName ?? "client") { kind, text in
                await addNote(kind: kind, text: text)
            }
        }
        .sheet(item: $signingTarget) { target in
            SignatureCaptureSheet(
                title: target.title,
                version: target.version,
                clientName: model.client?.fullName ?? "this client"
            ) {
                await sign(target)
            }
        }
        .confirmationDialog(
            "Request erasure of this client's data?",
            isPresented: $isConfirmingErasure,
            titleVisibility: .visible
        ) {
            Button("Request erasure", role: .destructive) {
                requestErasure()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The request is recorded on this file. Personal data is removed once statutory retention on bookings and invoices expires.")
        }
        .prvToast($model.toast)
    }

    // MARK: - States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "person.crop.circle.badge.exclamationmark",
            title: "Client unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    @ViewBuilder
    private func content(for client: ClientRecord) -> some View {
        ClientHeaderCard(client: client)

        ClientStatsRow(client: client, averageSpend: model.averageSpend)

        CRMSection("Beauty Profile", subtitle: "What every stylist should know") {
            BeautyProfileCard(client: client)
        }

        CRMSection("Colour History", subtitle: "Formulas, newest first") {
            ColorFormulaTimeline(formulas: model.colorFormulas)
        }

        tabbedSection
    }

    // MARK: - Tabs

    private var tabbedSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSegmentedGlassControl(
                selection: $tab,
                options: ClientDetailTab.allCases,
                title: \.title
            )

            switch tab {
            case .notes: notesTab
            case .visits: visitsTab
            case .consent: consentTab
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notesTab: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(
                "Notes",
                subtitle: model.generalNotes.isEmpty ? nil : "\(model.generalNotes.count) on file",
                actionTitle: "Add"
            ) {
                PRVHaptics.tap()
                isAddingNote = true
            }

            if model.generalNotes.isEmpty {
                PRVEmptyState(
                    systemImage: "square.and.pencil",
                    title: "No notes yet",
                    message: "Record preferences, sensitivities, and what worked — the next stylist will thank you.",
                    actionTitle: "Add Note"
                ) {
                    PRVHaptics.tap()
                    isAddingNote = true
                }
                .prvGlassCard()
            } else {
                LazyVStack(spacing: PRVSpacing.xs) {
                    ForEach(model.generalNotes) { note in
                        ClientNoteCard(note: note)
                    }
                }
            }
        }
    }

    // MARK: Visits

    @ViewBuilder
    private var visitsTab: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Visit History", subtitle: visitsSubtitle)

            if let message = model.visitsError {
                CRMErrorCard(message: message) { reload() }
            } else if !model.hasLinkedAccount {
                PRVEmptyState(
                    systemImage: "link.badge.plus",
                    title: "No linked account",
                    message: "This record was created by hand. Visits appear here once the client books with their PRV account."
                )
                .prvGlassCard()
            } else if model.visits.isEmpty {
                PRVEmptyState(
                    systemImage: "calendar",
                    title: "No visits yet",
                    message: "Their first appointment will appear here as soon as it is booked."
                )
                .prvGlassCard()
            } else {
                LazyVStack(spacing: PRVSpacing.xs) {
                    if !model.upcomingVisits.isEmpty {
                        Text("Upcoming")
                            .prvStyle(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(model.upcomingVisits) { appointment in
                            ClientVisitRow(appointment: appointment)
                        }
                    }
                    if !model.pastVisits.isEmpty {
                        Text("Past")
                            .prvStyle(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, model.upcomingVisits.isEmpty ? 0 : PRVSpacing.xs)
                        ForEach(model.pastVisits) { appointment in
                            ClientVisitRow(appointment: appointment)
                        }
                    }
                }
            }
        }
    }

    private var visitsSubtitle: String? {
        guard model.hasLinkedAccount, !model.visits.isEmpty else { return nil }
        return "\(model.pastVisits.count) past · \(model.upcomingVisits.count) upcoming"
    }

    // MARK: Consent

    @ViewBuilder
    private var consentTab: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSectionHeader(
                "Consent Forms",
                subtitle: model.signedForms.isEmpty ? "Nothing signed yet" : "\(model.signedForms.count) signed"
            )

            if !model.signedForms.isEmpty || !model.unsignedForms.isEmpty {
                VStack(spacing: PRVSpacing.sm) {
                    ForEach(model.unsignedForms) { form in
                        ConsentFormRow(form: form) {
                            signingTarget = .form(form)
                        }
                    }
                    ForEach(model.signedForms) { form in
                        ConsentFormRow(form: form) {
                            signingTarget = .form(form)
                        }
                    }
                }
                .prvGlassCard()
            }

            if !model.availableTemplates.isEmpty {
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    Text("Capture a signature")
                        .prvStyle(.footnote)

                    VStack(spacing: PRVSpacing.md) {
                        ForEach(model.availableTemplates) { template in
                            ConsentTemplateRow(template: template) {
                                signingTarget = .template(template)
                            }
                        }
                    }
                    .prvGlassCard()
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyMenu: some View {
        Menu {
            Section("Data protection") {
                Button("Prepare data export", systemImage: "square.and.arrow.down.on.square") {
                    PRVHaptics.impact()
                    model.prepareDataExport()
                }

                if let url = model.exportFileURL {
                    ShareLink(item: url) {
                        Label("Share data export", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section {
                Button("Request erasure", systemImage: "trash", role: .destructive) {
                    PRVHaptics.warning()
                    isConfirmingErasure = true
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Privacy and data options")
    }

    // MARK: - Actions

    private func refresh() async {
        await model.load(clientID: clientID, using: deps)
    }

    private func reload() {
        let deps = deps
        let clientID = clientID
        Task { await model.load(clientID: clientID, using: deps) }
    }

    private func addNote(kind: ClientNote.Kind, text: String) async {
        guard let authorID = session.currentUser?.id else { return }
        await model.addNote(kind: kind, text: text, authorID: authorID, using: deps)
    }

    private func sign(_ target: SigningTarget) async {
        switch target {
        case .template(let template):
            await model.signConsent(template: template, using: deps)
        case .form(let form):
            await model.signConsent(form: form, using: deps)
        }
    }

    private func requestErasure() {
        guard let actorID = session.currentUser?.id else { return }
        let deps = deps
        Task { await model.requestErasure(by: actorID, using: deps) }
    }
}

// MARK: - Tabs

/// The three views of a client record.
enum ClientDetailTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case notes
    case visits
    case consent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .visits: "Visits"
        case .consent: "Consent"
        }
    }
}

/// What the signature pad is capturing: a brand-new document from the standard
/// set, or a form already on file that is awaiting a signature.
enum SigningTarget: Identifiable, Hashable, Sendable {
    case template(ConsentTemplate)
    case form(ConsentForm)

    var id: String {
        switch self {
        case .template(let template): "template-\(template.id)"
        case .form(let form): "form-\(form.id.description)"
        }
    }

    var title: String {
        switch self {
        case .template(let template): template.title
        case .form(let form): form.title
        }
    }

    var version: String {
        switch self {
        case .template(let template): template.version
        case .form(let form): form.version
        }
    }
}

// MARK: - Previews

/// Resolves a real record from the in-memory backend before presenting the
/// detail screen: `ClientRecord` fixtures are seeded with generated
/// identifiers, so previews have to look one up rather than hard-code it.
private struct ClientDetailPreviewHost: View {
    @Environment(\.prvDependencies) private var deps
    @State private var clientID: ClientRecord.ID?

    var body: some View {
        NavigationStack {
            Group {
                if let clientID {
                    ClientDetailView(clientID: clientID)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.prv.canvas)
                }
            }
        }
        .task {
            clientID = try? await deps.crm
                .clients(salonID: PreviewData.salonLumiere.id, searchText: "")
                .first?
                .id
        }
    }
}

#Preview("Client — Owner") {
    let deps = PRVDependencies.inMemory()
    ClientDetailPreviewHost()
        .environment(\.prvDependencies, deps)
        .environment(UserSession.previewOwner)
        .environment(AppRouter(selectedTab: .clients))
}

#Preview("Client — Dark") {
    let deps = PRVDependencies.inMemory()
    ClientDetailPreviewHost()
        .environment(\.prvDependencies, deps)
        .environment(UserSession.previewOwner)
        .environment(AppRouter(selectedTab: .clients))
        .preferredColorScheme(.dark)
}
