import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// A structured appointment request rendered inside the transcript: what the
/// client wants, when they'd like it, and a one-tap route into the booking
/// flow. Until the referenced service resolves the card shows its own
/// skeleton rather than an empty shell.
struct AppointmentRequestCard: View {
    /// Service the request refers to.
    let serviceID: SalonService.ID
    /// The moment the client asked for.
    let preferredDate: Date
    /// Resolved service, when the lookup has landed.
    let service: SalonService?
    /// Salon to book at when the service itself carries none.
    let fallbackSalonID: Salon.ID?
    /// Whether the signed-in user authored the request.
    let isMine: Bool
    /// Opens the booking flow for a salon and service selection.
    let onChooseTime: (Salon.ID, [SalonService.ID]) -> Void

    private var salonID: Salon.ID? { service?.salonID ?? fallbackSalonID }

    var body: some View {
        PRVGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                header

                if let service {
                    resolvedBody(service)
                } else {
                    skeletonBody
                }

                Divider().overlay(Color.prv.separator)

                HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                    Image(systemName: "clock")
                        .font(.footnote)
                        .foregroundStyle(Color.prv.accent)
                        .accessibilityHidden(true)
                    Text(ChatFormat.appointmentMoment(preferredDate))
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    guard let salonID else { return }
                    PRVHaptics.impact()
                    onChooseTime(salonID, [serviceID])
                } label: {
                    Text("Choose time")
                }
                .buttonStyle(.prvPrimary)
                .disabled(salonID == nil)
                .accessibilityLabel("Choose a time for \(service?.name ?? "this treatment")")
                .accessibilityHint(salonID == nil ? "Available once the treatment loads" : "Opens the booking flow")
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isMine ? "Your appointment request" : "Appointment request")
    }

    private var header: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: "calendar.badge.clock")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.prv.accentGradient)
                .accessibilityHidden(true)
            Text("Appointment request")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.prv.textSecondary)
                .textCase(.uppercase)
        }
    }

    private func resolvedBody(_ service: SalonService) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(service.name)
                .prvStyle(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: PRVSpacing.xs) {
                PRVTag(
                    ChatFormat.serviceDuration(minutes: service.durationMinutes),
                    systemImage: "hourglass"
                )
                PRVTag(service.category.displayName, systemImage: service.category.symbolName)
            }

            PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
        }
    }

    private var skeletonBody: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            PRVSkeleton(width: 170, height: 17)
            PRVSkeleton(width: 120, height: 12)
        }
    }
}

/// Lets a client attach a structured appointment request to the conversation:
/// pick the treatment, pick when you'd like it, send. The salon receives a
/// card it can act on instead of free text it has to interpret.
struct AppointmentRequestSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Salon whose menu is offered.
    let salonID: Salon.ID
    /// Called with the chosen treatment and moment once the user confirms.
    let onSubmit: (SalonService.ID, Date) -> Void

    @State private var phase: ChatPhase = .loading
    @State private var services: [SalonService] = []
    @State private var selectedServiceID: SalonService.ID?
    @State private var preferredDate = Date.now.adding(days: 1)
    @State private var isSubmitting = false

    /// The soonest moment worth requesting.
    private var earliestDate: Date { Date.now.adding(minutes: 60) }

    private var canSubmit: Bool {
        selectedServiceID != nil && !isSubmitting && session.can(.book)
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.prv.canvas)
                .navigationTitle("Request a Time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSubmitting)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ScrollView {
                VStack(spacing: PRVSpacing.sm) {
                    ForEach(0..<4, id: \.self) { _ in
                        HStack(spacing: PRVSpacing.sm) {
                            PRVSkeleton(width: 36, height: 36, radius: PRVRadius.sm)
                            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                                PRVSkeleton(width: 150, height: 15)
                                PRVSkeleton(width: 100, height: 11)
                            }
                            Spacer()
                        }
                        .prvGlassCard(radius: PRVRadius.md, padding: PRVSpacing.sm)
                    }
                }
                .padding(PRVSpacing.md)
            }
            .scrollDisabled(true)

        case .failed(let message):
            ChatErrorCard(message: message) {
                Task { await load() }
            }
            .padding(PRVSpacing.md)
            .frame(maxHeight: .infinity, alignment: .top)

        case .loaded:
            if services.isEmpty {
                PRVEmptyState(
                    systemImage: "list.bullet.rectangle",
                    title: "No treatments listed",
                    message: "This salon hasn't published a menu yet. Send a message describing what you'd like instead."
                )
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                form
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Treatment")
                        .prvStyle(.headline)

                    VStack(spacing: PRVSpacing.xs) {
                        ForEach(services) { service in
                            serviceRow(service)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Preferred time")
                        .prvStyle(.headline)

                    DatePicker(
                        "Preferred time",
                        selection: $preferredDate,
                        in: earliestDate...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Color.prv.accent)
                    .accessibilityLabel("Preferred date and time")
                }

                Button {
                    submit()
                } label: {
                    Text("Send Request")
                }
                .buttonStyle(.prvPrimary)
                .disabled(!canSubmit)
                .accessibilityHint("Sends a structured appointment request to the salon")

                if !session.can(.book) {
                    Text("Sign in to request an appointment.")
                        .prvStyle(.footnote)
                }
            }
            .padding(PRVSpacing.md)
        }
        .prvAnimation(PRVMotion.quick, value: selectedServiceID)
    }

    private func serviceRow(_ service: SalonService) -> some View {
        Button {
            PRVHaptics.tap()
            selectedServiceID = service.id
        } label: {
            PRVListRow(
                title: service.name,
                subtitle: ChatFormat.serviceDuration(minutes: service.durationMinutes)
            ) {
                PRVListRowIcon(systemImage: service.category.symbolName)
            } trailing: {
                HStack(spacing: PRVSpacing.xs) {
                    PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
                    Image(systemName: selectedServiceID == service.id ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(
                            selectedServiceID == service.id
                                ? Color.prv.accent
                                : Color.prv.textSecondary.opacity(0.5)
                        )
                }
            }
            .prvGlassCard(radius: PRVRadius.md, padding: PRVSpacing.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(service.name), \(service.price.formatted)")
        .accessibilityAddTraits(selectedServiceID == service.id ? [.isSelected] : [])
    }

    // MARK: - Actions

    private func load() async {
        if services.isEmpty { phase = .loading }
        do {
            let loaded = try await deps.salons.services(salonID: salonID)
            services = loaded.filter(\.isActive)
            selectedServiceID = selectedServiceID ?? services.first?.id
            phase = .loaded
        } catch {
            phase = .failed(ChatErrorCopy.loadFailure(error))
        }
    }

    private func submit() {
        guard let selectedServiceID, canSubmit else { return }
        isSubmitting = true
        PRVHaptics.success()
        onSubmit(selectedServiceID, preferredDate)
        dismiss()
    }
}

#Preview("Appointment Request Card") {
    VStack(spacing: PRVSpacing.md) {
        AppointmentRequestCard(
            serviceID: PreviewData.serviceBalayage.id,
            preferredDate: Date.now.addingTimeInterval(60 * 60 * 48),
            service: PreviewData.serviceBalayage,
            fallbackSalonID: PreviewData.salonLumiere.id,
            isMine: true,
            onChooseTime: { _, _ in }
        )

        AppointmentRequestCard(
            serviceID: PreviewData.serviceGelManicure.id,
            preferredDate: Date.now.addingTimeInterval(60 * 60 * 72),
            service: nil,
            fallbackSalonID: nil,
            isMine: false,
            onChooseTime: { _, _ in }
        )
    }
    .padding(PRVSpacing.lg)
    .frame(maxHeight: .infinity)
    .background(Color.prv.canvas)
}

#Preview("Appointment Request Sheet") {
    AppointmentRequestSheet(salonID: PreviewData.salonLumiere.id) { _, _ in }
        .environment(UserSession.previewClient)
        .environment(AppRouter())
}
