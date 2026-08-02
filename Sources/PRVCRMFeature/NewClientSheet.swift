import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Creates a client record by hand — the walk-in path, for people who did not
/// arrive through an online booking.
///
/// Only a name is required; everything else enriches the beauty profile that
/// the detail screen shows. Saving writes straight through `upsertClient`.
struct NewClientSheet: View {
    @Environment(\.dismiss) private var dismiss

    let salonID: Salon.ID
    /// Persists the record; returns `true` when the write succeeded.
    let save: @MainActor (ClientRecord) async -> Bool

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var hasBirthday = false
    @State private var birthday = Date.now
    @State private var skinType = ""
    @State private var hairType = ""
    @State private var allergies = ""
    @State private var preferences = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                    identitySection
                    contactSection
                    beautyProfileSection
                }
                .padding(PRVSpacing.lg)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .fontWeight(.semibold)
                        .disabled(!canSave || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .padding(PRVSpacing.lg)
                        .prvGlassCard()
                        .accessibilityLabel("Saving client")
                }
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        CRMSection("Who they are") {
            VStack(spacing: PRVSpacing.sm) {
                CRMTextField(title: "First name", text: $firstName, systemImage: "person", kind: .name)
                CRMTextField(title: "Last name", text: $lastName, systemImage: "person", kind: .name)

                Toggle(isOn: $hasBirthday) {
                    Text("Birthday")
                        .font(.body)
                        .foregroundStyle(Color.prv.textPrimary)
                }
                .tint(Color.prv.accent)

                if hasBirthday {
                    DatePicker(
                        "Birthday",
                        selection: $birthday,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .tint(Color.prv.accent)
                }
            }
            .prvGlassCard()
            .prvAnimation(PRVMotion.quick, value: hasBirthday)
        }
    }

    private var contactSection: some View {
        CRMSection("How to reach them") {
            VStack(spacing: PRVSpacing.sm) {
                CRMTextField(title: "Email", text: $email, systemImage: "envelope", kind: .email)
                CRMTextField(title: "Phone", text: $phone, systemImage: "phone", kind: .phone)
            }
            .prvGlassCard()
        }
    }

    private var beautyProfileSection: some View {
        CRMSection("Beauty profile", subtitle: "Optional, but it makes every visit better") {
            VStack(spacing: PRVSpacing.sm) {
                CRMTextField(title: "Skin type", text: $skinType, systemImage: "drop")
                CRMTextField(title: "Hair type", text: $hairType, systemImage: "comb")
                CRMTextField(
                    title: "Allergies, comma separated",
                    text: $allergies,
                    systemImage: "exclamationmark.triangle"
                )
                CRMTextField(
                    title: "Preferences, comma separated",
                    text: $preferences,
                    systemImage: "heart"
                )
            }
            .prvGlassCard()
        }
    }

    // MARK: - Actions

    private var canSave: Bool {
        !firstName.isBlank && !lastName.isBlank
    }

    private func submit() {
        guard canSave, !isSaving else { return }
        isSaving = true
        let record = ClientRecord(
            salonID: salonID,
            firstName: firstName.trimmed,
            lastName: lastName.trimmed,
            email: email.isBlank ? nil : email.trimmed,
            phone: phone.isBlank ? nil : phone.trimmed,
            birthday: hasBirthday ? birthday : nil,
            skinType: skinType.isBlank ? nil : skinType.trimmed,
            hairType: hairType.isBlank ? nil : hairType.trimmed,
            allergies: Self.list(from: allergies),
            preferences: Self.list(from: preferences)
        )

        Task {
            let succeeded = await save(record)
            isSaving = false
            if succeeded { dismiss() }
        }
    }

    /// Splits a comma-separated field into trimmed, non-empty entries.
    static func list(from text: String) -> [String] {
        text
            .split(separator: ",")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Field

/// A glass text input matching the platform's form language.
///
/// The keyboard/content-type combination is chosen by ``Kind`` so the view
/// never has to name UIKit types.
struct CRMTextField: View {
    /// What the field collects, which drives keyboard and autofill behaviour.
    enum Kind: Hashable, Sendable {
        case name
        case email
        case phone
        case freeText
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let title: String
    @Binding var text: String
    var systemImage: String? = nil
    var kind: Kind = .freeText

    var body: some View {
        HStack(spacing: PRVSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(Color.prv.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }

            field
                .font(.body)
                .foregroundStyle(Color.prv.textPrimary)
                .accessibilityLabel(title)
        }
        .padding(.vertical, PRVSpacing.sm)
        .padding(.horizontal, PRVSpacing.md)
        .background {
            if reduceTransparency {
                PRVRadius.shape(PRVRadius.md).fill(Color.prv.surface)
            } else {
                PRVRadius.shape(PRVRadius.md).fill(.ultraThinMaterial)
            }
        }
        .overlay {
            PRVRadius.shape(PRVRadius.md)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var field: some View {
        switch kind {
        case .name:
            TextField(title, text: $text)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
        case .email:
            TextField(title, text: $text)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .phone:
            TextField(title, text: $text)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        case .freeText:
            TextField(title, text: $text)
                .textInputAutocapitalization(.sentences)
        }
    }
}

// MARK: - Previews

#Preview("New Client") {
    NewClientSheet(salonID: PreviewData.salonLumiere.id) { _ in true }
}

#Preview("New Client — Dark") {
    NewClientSheet(salonID: PreviewData.salonLumiere.id) { _ in true }
        .preferredColorScheme(.dark)
}
