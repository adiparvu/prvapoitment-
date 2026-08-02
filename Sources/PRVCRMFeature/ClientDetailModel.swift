import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model behind ``ClientDetailView``.
///
/// Loads the record, its notes, its consent forms, and — when the client has a
/// linked platform account — their visit history, all concurrently. Owns every
/// mutation the screen offers: adding notes, capturing consent signatures, and
/// the two GDPR obligations (portable export, erasure request).
@Observable
@MainActor
final class ClientDetailModel {
    // MARK: State

    private(set) var phase: CRMPhase = .loading
    private(set) var client: ClientRecord?
    private(set) var notes: [ClientNote] = []
    private(set) var consentForms: [ConsentForm] = []
    private(set) var visits: [Appointment] = []
    private(set) var visitsError: String?
    private(set) var isSaving = false
    private(set) var hasLoadedOnce = false

    /// Prepared GDPR export, surfaced as a `ShareLink` item once written.
    private(set) var exportFileURL: URL?

    var toast: PRVToast?

    // MARK: Derived

    /// Colour formulas, newest first — the timeline a colourist lives in.
    var colorFormulas: [ClientNote] {
        notes.filter { $0.kind == .colorFormula }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Everything that is not a colour formula, newest first.
    var generalNotes: [ClientNote] {
        notes.filter { $0.kind != .colorFormula }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Completed visits, most recent first.
    var pastVisits: [Appointment] {
        visits
            .filter { ($0.start ?? .distantFuture) <= .now }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    /// Still-to-come appointments, soonest first.
    var upcomingVisits: [Appointment] {
        visits
            .filter { $0.status.isActive && ($0.start ?? .distantPast) > .now }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Whether the record is linked to a platform account (which is what makes
    /// visit history and portable exports possible).
    var hasLinkedAccount: Bool { client?.userID != nil }

    /// Consent forms that have been signed, newest first.
    var signedForms: [ConsentForm] {
        consentForms
            .filter { $0.signedAt != nil }
            .sorted { ($0.signedAt ?? .distantPast) > ($1.signedAt ?? .distantPast) }
    }

    /// Forms on file that still need a signature.
    var unsignedForms: [ConsentForm] {
        consentForms.filter { $0.signedAt == nil }
    }

    /// Standard documents the client has not signed at their current version.
    var availableTemplates: [ConsentTemplate] {
        ConsentTemplate.standard.filter { template in
            !consentForms.contains {
                $0.title == template.title && $0.version == template.version && $0.signedAt != nil
            }
        }
    }

    /// Average spend per visit, for the stats row.
    var averageSpend: Money {
        guard let client, client.totalVisits > 0 else { return .zero() }
        return Money(
            (client.totalSpend.amount / Decimal(client.totalVisits)).rounded(),
            client.totalSpend.currency
        )
    }

    // MARK: Loading

    /// Loads the record and everything hanging off it.
    func load(clientID: ClientRecord.ID, using deps: PRVDependencies) async {
        if !hasLoadedOnce { phase = .loading }

        async let notesTask = deps.crm.notes(clientRecordID: clientID)
        async let formsTask = deps.crm.consentForms(clientRecordID: clientID)

        do {
            let record = try await deps.crm.client(id: clientID)
            client = record
            phase = .loaded
            await loadVisits(for: record, using: deps)
        } catch {
            phase = .failed(CRMCopy.friendlyMessage(for: error))
        }

        notes = (try? await notesTask) ?? []
        consentForms = (try? await formsTask) ?? []
        hasLoadedOnce = true
    }

    /// Visit history comes from the appointment repository and needs the
    /// client's platform account; walk-in records simply have none.
    private func loadVisits(for record: ClientRecord, using deps: PRVDependencies) async {
        guard let userID = record.userID else {
            visits = []
            visitsError = nil
            return
        }
        do {
            visits = try await deps.appointments.appointments(clientID: userID)
            visitsError = nil
        } catch {
            visits = []
            visitsError = CRMCopy.friendlyMessage(for: error)
        }
    }

    // MARK: Notes

    /// Adds a note to the client's file.
    func addNote(
        kind: ClientNote.Kind,
        text: String,
        authorID: User.ID,
        using deps: PRVDependencies
    ) async {
        guard let client, !text.isBlank, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let note = ClientNote(
            clientRecordID: client.id,
            authorID: authorID,
            kind: kind,
            text: text.trimmed
        )
        do {
            let saved = try await deps.crm.addNote(note)
            notes.append(saved)
            PRVHaptics.success()
            toast = .success("\(kind.title) saved")
        } catch {
            PRVHaptics.error()
            toast = .error(CRMCopy.friendlyMessage(for: error))
        }
    }

    // MARK: Consent

    /// Records a signature against a standard document, creating the form.
    func signConsent(template: ConsentTemplate, using deps: PRVDependencies) async {
        guard let client else { return }
        let form = ConsentForm(
            clientRecordID: client.id,
            title: template.title,
            version: template.version,
            signedAt: .now
        )
        await save(form, using: deps)
    }

    /// Records a signature against a form already on file.
    func signConsent(form: ConsentForm, using deps: PRVDependencies) async {
        var signed = form
        signed.signedAt = .now
        await save(signed, using: deps)
    }

    private func save(_ form: ConsentForm, using deps: PRVDependencies) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let saved = try await deps.crm.saveConsentForm(form)
            if let index = consentForms.firstIndex(where: { $0.id == saved.id }) {
                consentForms[index] = saved
            } else {
                consentForms.append(saved)
            }
            PRVHaptics.success()
            toast = .success("\(saved.title) signed")
        } catch {
            PRVHaptics.error()
            toast = .error(CRMCopy.friendlyMessage(for: error))
        }
    }

    // MARK: GDPR

    /// Writes a portable JSON export of everything the salon holds on this
    /// client and exposes it for sharing (GDPR Article 20).
    func prepareDataExport() {
        guard let client else { return }
        let payload = ClientDataExport(
            exportedAt: .now,
            client: client,
            notes: notes.sorted { $0.createdAt < $1.createdAt },
            consentForms: consentForms,
            visits: visits.map(ClientDataExport.Visit.init)
        )
        do {
            exportFileURL = try ClientDataExport.write(payload, for: client)
            PRVHaptics.success()
            toast = .success("Data export ready to share")
        } catch {
            PRVHaptics.error()
            toast = .error("We couldn't build the export. Try again in a moment.")
        }
    }

    /// Files an erasure request (GDPR Article 17).
    ///
    /// Erasure is never immediate: bookings and invoices carry statutory
    /// retention, so the request is recorded on the client's file as an audited
    /// note for the data controller to action.
    func requestErasure(by actorID: User.ID, using deps: PRVDependencies) async {
        guard let client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let note = ClientNote(
            clientRecordID: client.id,
            authorID: actorID,
            kind: .general,
            text: "GDPR erasure requested on \(Date.now.formatted(date: .abbreviated, time: .shortened)). Personal data to be removed once statutory retention on bookings and invoices expires."
        )
        do {
            let saved = try await deps.crm.addNote(note)
            notes.append(saved)
            PRVHaptics.warning()
            toast = .warning("Erasure request recorded on this file")
        } catch {
            PRVHaptics.error()
            toast = .error(CRMCopy.friendlyMessage(for: error))
        }
    }
}

// MARK: - Export payload

/// The GDPR data-portability document: everything the salon holds on one
/// client, in a machine-readable shape.
struct ClientDataExport: Codable, Sendable {
    /// A visit reduced to the fields a client is entitled to receive.
    struct Visit: Codable, Sendable {
        var appointmentID: String
        var salonName: String
        var status: String
        var start: Date?
        var end: Date?
        var services: [String]
        var total: Decimal
        var currency: String

        init(_ appointment: Appointment) {
            self.appointmentID = appointment.id.description
            self.salonName = appointment.salonName
            self.status = appointment.status.rawValue
            self.start = appointment.start
            self.end = appointment.end
            self.services = appointment.items.map(\.serviceName)
            self.total = appointment.totalPrice.amount
            self.currency = appointment.totalPrice.currency.rawValue
        }
    }

    var exportedAt: Date
    var client: ClientRecord
    var notes: [ClientNote]
    var consentForms: [ConsentForm]
    var visits: [Visit]

    /// Encoder matching the platform's wire format, with pretty printing and
    /// stable key order so the file is readable by a human too.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Writes the export into the temporary directory and returns its URL.
    static func write(_ payload: ClientDataExport, for client: ClientRecord) throws -> URL {
        let data = try makeEncoder().encode(payload)
        let slug = client.fullName
            .folding(options: [.diacriticInsensitive], locale: .current)
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let name = String(slug)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .lowercased()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.isEmpty ? "client" : name)-data-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
