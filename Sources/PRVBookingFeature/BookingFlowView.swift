import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The flagship booking flow: four glass steps — services, artist, time,
/// review & pay — with a morphing progress indicator, then the confirmation
/// seal.
///
/// Every step is driven by ``BookingFlowModel``; data comes exclusively from
/// `@Environment(\.prvDependencies)` and navigation from the shared
/// `AppRouter`. Confirming books the appointment, creates its order, and
/// presents checkout for whatever the client chose to prepay.
///
/// ```swift
/// BookingFlowView(
///     context: BookingContext(salonID: salon.id, serviceIDs: selectedIDs)
/// )
/// ```
public struct BookingFlowView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: BookingFlowModel

    /// Creates the flow for a salon and an optional pre-selection of services.
    public init(context: BookingContext) {
        _model = State(initialValue: BookingFlowModel(context: context))
    }

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: PRVSpacing.md) {
            if model.step != .confirmation, model.phase == .loaded {
                BookingProgressBar(
                    step: model.step,
                    furthestStep: model.furthestStep,
                    onSelect: { model.jump(to: $0) }
                )
                .padding(.horizontal, PRVSpacing.md)
                .padding(.top, PRVSpacing.xs)
            }

            ScrollView {
                content
                    .padding(.horizontal, PRVSpacing.md)
                    .padding(.bottom, PRVSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.prv.canvas)
        .navigationTitle(model.step.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.step != .confirmation, model.phase == .loaded {
                PRVBottomBar { bottomBar }
            }
        }
        .sheet(isPresented: $model.isWaitlistPresented) { waitlistSheet }
        .prvToast($model.toast)
        .task { await model.load(using: deps) }
        .prvAnimation(PRVMotion.morph, value: model.step)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            BookingLoadingView()
                .padding(.top, PRVSpacing.md)
        case .failed(let message):
            BookingErrorCard(message: message) {
                Task { await model.load(using: deps) }
            }
            .padding(.top, PRVSpacing.xl)
        case .loaded:
            ZStack(alignment: .top) {
                stepContent
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .services:
            ServiceSelectionStepView(model: model)
                .transition(stepTransition)
        case .professional:
            ProfessionalSelectionStepView(model: model)
                .transition(stepTransition)
        case .time:
            TimeSelectionStepView(model: model, reloadSlots: reloadSlots)
                .transition(stepTransition)
                .task(id: model.slotRequestKey) {
                    await model.loadSlots(using: deps)
                }
        case .review:
            ReviewPayStepView(
                model: model,
                onEdit: { model.jump(to: $0) },
                applyCoupon: { Task { await model.applyCoupon(using: deps) } }
            )
            .transition(stepTransition)
        case .confirmation:
            if let confirmation = model.confirmation {
                BookingConfirmationView(
                    confirmation: confirmation,
                    onPayNow: { router.present(.checkout(confirmation.order.id)) },
                    onDone: finish,
                    onMessage: { model.toast = $0 }
                )
                .transition(stepTransition)
            }
        }
    }

    /// The liquid morph between steps — a soft scale-and-fade that reads as
    /// one surface reshaping, flattened to a cross-fade under Reduce Motion.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.97).combined(with: .opacity),
            removal: .scale(scale: 1.02).combined(with: .opacity)
        )
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: PRVSpacing.sm) {
            if !model.selectedServices.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.step == .review ? "Charged today" : "Total")
                            .prvStyle(.caption)
                        PRVPriceLabel(
                            model.step == .review ? model.dueToday.formatted : model.orderTotal.formatted,
                            emphasis: .prominent
                        )
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(selectionSummary)
                            .prvStyle(.caption)
                        if let slot = model.selectedSlot, model.step >= .time {
                            Text(BookingFormatting.shortDay(slot.start) + " · " + BookingFormatting.time(slot.start))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.prv.accent)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: PRVSpacing.sm) {
                if model.step != .services {
                    Button {
                        model.retreat()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.prvGlass)
                    .accessibilityLabel("Back to \(model.step.previous?.shortTitle ?? "the previous step")")
                }

                Button {
                    primaryAction()
                } label: {
                    if model.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.prv.textOnAccent)
                    } else {
                        Text(model.primaryActionTitle)
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(!model.canAdvance)
                .accessibilityLabel(model.primaryActionTitle)
                .accessibilityHint(primaryActionHint)
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.step)
    }

    private var selectionSummary: String {
        let count = model.selectedServices.count
        let services = count == 1 ? "1 treatment" : "\(count) treatments"
        guard model.totalDurationMinutes > 0 else { return services }
        return "\(services) · \(BookingFormatting.duration(model.totalDurationMinutes))"
    }

    private var primaryActionHint: String {
        switch model.step {
        case .services: model.canAdvance ? "" : "Add at least one treatment to continue"
        case .time: model.canAdvance ? "" : "Choose a time to continue"
        case .review: "Books your appointment and opens checkout"
        default: ""
        }
    }

    // MARK: - Sheets

    private var waitlistSheet: some View {
        WaitlistSheet(
            serviceName: model.primaryService?.name ?? "your treatment",
            professionalName: model.selectedProfessional?.displayName,
            day: model.selectedDay,
            isJoining: model.isJoiningWaitlist,
            join: { earliest, latest in
                guard let user = session.currentUser else {
                    model.toast = .warning("Sign in to join the waitlist.")
                    return false
                }
                return await model.joinWaitlist(
                    earliest: earliest,
                    latest: latest,
                    clientID: user.id,
                    using: deps
                )
            }
        )
    }

    // MARK: - Actions

    private func primaryAction() {
        if model.step == .review {
            Task { await confirm() }
        } else {
            model.advance()
        }
    }

    /// Books the appointment, then opens checkout for anything due today.
    private func confirm() async {
        guard let user = session.currentUser else {
            model.toast = .warning("Sign in to complete your booking.")
            return
        }
        guard let orderID = await model.confirm(clientID: user.id, using: deps) else { return }
        if let confirmation = model.confirmation, !confirmation.amountDueNow.isZero {
            router.present(.checkout(orderID))
        }
    }

    private func reloadSlots() {
        Task { await model.loadSlots(using: deps) }
    }

    /// Leaves the flow for the client's bookings list.
    private func finish() {
        router.popToRoot()
        router.selectedTab = .appointments
    }
}

/// The first-load skeleton: a menu's worth of shimmering service cards.
struct BookingLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSkeleton(width: 160, height: 22)
            ForEach(0..<4, id: \.self) { _ in
                PRVGlassCard {
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        PRVSkeleton(width: 180, height: 18)
                        PRVSkeleton(height: 12)
                        PRVSkeleton(width: 120, height: 12)
                    }
                }
            }
        }
        .accessibilityLabel("Loading the salon's menu")
    }
}

// MARK: - Previews

#Preview("Booking Flow — Client") {
    NavigationStack {
        BookingFlowView(
            context: BookingContext(
                salonID: PreviewData.salonLumiere.id,
                serviceIDs: [PreviewData.serviceBalayage.id]
            )
        )
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Booking Flow — Dark") {
    NavigationStack {
        BookingFlowView(
            context: BookingContext(salonID: PreviewData.salonVelvet.id)
        )
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
