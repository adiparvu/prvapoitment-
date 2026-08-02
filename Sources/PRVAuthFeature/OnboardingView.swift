import SwiftUI
import Observation
import UserNotifications
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// First-run onboarding: four swipeable glass pages (discover, book, loyalty,
/// business) with liquid morph transitions, followed by a notification
/// pre-permission explainer, finishing into the authentication experience.
public struct OnboardingView: View {
    @State private var model = OnboardingModel()

    /// Creates the onboarding flow. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        ZStack {
            AuroraBackground()

            switch model.stage {
            case .pages:
                pagesStage
                    .transition(Self.stageTransition)
            case .notifications:
                NotificationPrimerView(model: model)
                    .transition(Self.stageTransition)
            case .auth:
                AuthRootView()
                    .transition(Self.stageTransition)
            }
        }
        .prvAnimation(PRVMotion.morph, value: model.stage)
    }

    /// Liquid morph between onboarding stages: content breathes in with a
    /// gentle scale-and-rise, and exhales slightly as it leaves.
    private static var stageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.94))
                .combined(with: .offset(y: PRVSpacing.xl)),
            removal: .opacity.combined(with: .scale(scale: 1.04))
        )
    }

    // MARK: - Pages stage

    private var pagesStage: some View {
        VStack(spacing: PRVSpacing.lg) {
            HStack {
                Spacer()
                Button("Skip") {
                    model.skip()
                }
                .buttonStyle(.prvGlass)
                .accessibilityLabel("Skip onboarding")
            }
            .padding(.horizontal, PRVSpacing.lg)

            TabView(selection: $model.pageIndex) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageCard(page: page)
                        .padding(.horizontal, PRVSpacing.lg)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .prvAnimation(PRVMotion.gentle, value: model.pageIndex)

            pageDots

            Button(model.isLastPage ? "Get Started" : "Continue") {
                model.advance()
            }
            .buttonStyle(.prvPrimary)
            .padding(.horizontal, PRVSpacing.lg)
            .accessibilityLabel(model.isLastPage ? "Get started" : "Continue to next page")
        }
        .padding(.vertical, PRVSpacing.lg)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var pageDots: some View {
        HStack(spacing: PRVSpacing.xs) {
            ForEach(model.pages.indices, id: \.self) { index in
                Capsule()
                    .fill(
                        index == model.pageIndex
                            ? AnyShapeStyle(Color.prv.accentGradient)
                            : AnyShapeStyle(Color.prv.textSecondary.opacity(0.3))
                    )
                    .frame(width: index == model.pageIndex ? 22 : 8, height: 8)
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.pageIndex)
        .accessibilityElement()
        .accessibilityLabel("Page \(model.pageIndex + 1) of \(model.pages.count)")
    }
}

// MARK: - Model

/// Drives the onboarding flow: page position, stage progression, and the
/// notification pre-permission request.
@Observable
@MainActor
final class OnboardingModel {
    /// The three phases of onboarding, in order.
    enum Stage: Equatable, Sendable {
        case pages
        case notifications
        case auth
    }

    var stage: Stage = .pages
    var pageIndex = 0
    private(set) var isRequestingNotifications = false

    let pages = OnboardingPage.all

    var isLastPage: Bool { pageIndex >= pages.count - 1 }

    /// Moves to the next page, or into the notification explainer after the
    /// final page.
    func advance() {
        PRVHaptics.tap()
        if isLastPage {
            stage = .notifications
        } else {
            pageIndex += 1
        }
    }

    /// Skips straight to authentication.
    func skip() {
        PRVHaptics.tap()
        stage = .auth
    }

    /// Declines the notification explainer and continues into auth.
    func declineNotifications() {
        PRVHaptics.tap()
        stage = .auth
    }

    /// Requests notification permission (the system prompt only ever appears
    /// after our explainer), then continues into auth regardless of outcome.
    func requestNotificationPermission() async {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        defer { isRequestingNotifications = false }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            if granted { PRVHaptics.success() }
            PRVLog.auth.info("Notification pre-permission granted: \(granted)")
        } catch {
            PRVLog.auth.error("Notification permission request failed: \(String(describing: error), privacy: .public)")
        }
        stage = .auth
    }
}

/// One swipeable onboarding page.
struct OnboardingPage: Identifiable, Hashable, Sendable {
    let id: String
    let symbol: String
    let title: String
    let message: String

    static let all: [OnboardingPage] = [
        OnboardingPage(
            id: "discover",
            symbol: "sparkle.magnifyingglass",
            title: "Discover your next look",
            message: "AI-powered search matches you with the right salon, artist, and style — nearby and on your terms."
        ),
        OnboardingPage(
            id: "book",
            symbol: "calendar.badge.clock",
            title: "Book in seconds",
            message: "Live availability, instant confirmation, and effortless rescheduling. Your chair is always a tap away."
        ),
        OnboardingPage(
            id: "loyalty",
            symbol: "crown.fill",
            title: "Loyalty that pampers",
            message: "Earn XP with every visit, unlock tiers, and enjoy member-only perks at your favorite salons."
        ),
        OnboardingPage(
            id: "business",
            symbol: "chart.bar.xaxis",
            title: "Built for pros too",
            message: "Run your salon end to end — calendar, team, clients, and payments in one beautiful studio."
        ),
    ]
}

/// A single glass onboarding page: gradient orb, title, and message.
struct OnboardingPageCard: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: PRVSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.prv.accentGradient)
                    .frame(width: 96, height: 96)
                    .prvSoftShadow()
                Image(systemName: page.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.prv.textOnAccent)
            }
            .accessibilityHidden(true)

            Text(page.title)
                .prvStyle(.title)
                .multilineTextAlignment(.center)

            Text(page.message)
                .prvStyle(.subheadline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(page.message)")
    }
}

// MARK: - Notification pre-permission explainer

/// Explains why notifications are worth enabling *before* the one-shot system
/// prompt appears, with a graceful "maybe later" path.
struct NotificationPrimerView: View {
    let model: OnboardingModel

    var body: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.lg) {
                ZStack {
                    Circle()
                        .fill(Color.prv.accentGradient)
                        .frame(width: 96, height: 96)
                        .prvSoftShadow()
                    Image(systemName: "bell.badge.fill")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(Color.prv.textOnAccent)
                }
                .accessibilityHidden(true)

                Text("Stay in the loop")
                    .prvStyle(.title)

                Text("Timely nudges only — never noise. You're always in control.")
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    benefitRow("clock.badge.fill", "Appointment reminders before every visit")
                    benefitRow("sparkles", "Waitlist openings the moment a slot frees up")
                    benefitRow("gift.fill", "Loyalty rewards and member-only offers")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .prvGlassCard()

                Button {
                    Task { await model.requestNotificationPermission() }
                } label: {
                    if model.isRequestingNotifications {
                        ProgressView()
                            .tint(Color.prv.textOnAccent)
                    } else {
                        Text("Enable Notifications")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(model.isRequestingNotifications)
                .accessibilityLabel("Enable notifications")

                Button("Maybe Later") {
                    model.declineNotifications()
                }
                .buttonStyle(.prvGlass)
                .accessibilityHint("Continues without enabling notifications. You can enable them anytime in Settings.")

                Text("You can change this anytime in Settings.")
                    .prvStyle(.caption)
            }
            .padding(PRVSpacing.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func benefitRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(Color.prv.accent)
                .frame(width: PRVSpacing.xl)
            Text(text)
                .prvStyle(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Onboarding") {
    OnboardingView()
        .environment(UserSession())
}

#Preview("Notification primer") {
    let model = OnboardingModel()
    model.stage = .notifications
    return NotificationPrimerView(model: model)
        .environment(UserSession.previewClient)
}

#Preview("Onboarding — dark") {
    OnboardingView()
        .environment(UserSession())
        .preferredColorScheme(.dark)
}
