import SwiftUI
import AuthenticationServices
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The cinematic welcome and authentication experience: an animated
/// accent-gradient glass hero, the platform's value propositions, Sign in
/// with Apple, email sign-in/sign-up with inline validation, and a guest
/// browsing entry that clearly communicates what stays locked until sign-in.
///
/// On success the shared `UserSession` is updated via `signedIn(_:)` and the
/// success haptic plays. Data access goes exclusively through
/// `@Environment(\.prvDependencies)`.
public struct AuthRootView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var model = AuthModel()
    @State private var isShowingGuestSheet = false
    @State private var hasAppeared = false
    @FocusState private var focusedField: Field?
    @Namespace private var modeIndicator

    private enum Field: Hashable {
        case firstName, lastName, email, password
    }

    /// Creates the welcome experience. All dependencies come from the
    /// environment; the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        ZStack {
            AuroraBackground()

            ScrollView {
                VStack(spacing: PRVSpacing.xl) {
                    hero
                    valueProps
                    signInCard
                    guestEntry
                }
                .padding(.horizontal, PRVSpacing.lg)
                .padding(.vertical, PRVSpacing.xxl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : PRVSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .prvAnimation(PRVMotion.gentle, value: hasAppeared)
        .prvAnimation(PRVMotion.spring, value: model.errorMessage)
        .prvAnimation(PRVMotion.morph, value: model.mode)
        .onAppear { hasAppeared = true }
        .sheet(isPresented: $isShowingGuestSheet) {
            GuestLimitsSheet {
                isShowingGuestSheet = false
                // The session intentionally stays unauthenticated; dismissing
                // the auth surface hands control back to the host, which
                // presents the guest (browse-only) experience.
                dismiss()
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: PRVSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.prv.accentGradient)
                    .frame(width: 88, height: 88)
                    .prvSoftShadow()
                Image(systemName: "sparkles")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.prv.textOnAccent)
            }
            .accessibilityHidden(true)

            Text("PRV Beauty")
                .prvStyle(.display)

            Text("Your beauty world, beautifully organized.")
                .prvStyle(.subheadline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PRV Beauty. Your beauty world, beautifully organized.")
    }

    // MARK: - Value propositions

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            valuePropRow(
                symbol: "sparkle.magnifyingglass",
                title: "Discover",
                detail: "AI-matched salons, artists, and styles around you."
            )
            valuePropRow(
                symbol: "calendar.badge.clock",
                title: "Book in seconds",
                detail: "Live availability, instant confirmation, easy rescheduling."
            )
            valuePropRow(
                symbol: "crown.fill",
                title: "Earn as you glow",
                detail: "Loyalty XP, tiers, and member-only perks at every visit."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard()
    }

    private func valuePropRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.prv.accentGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.prv.textOnAccent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(title).prvStyle(.headline)
                Text(detail).prvStyle(.footnote)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Sign-in card

    private var signInCard: some View {
        VStack(spacing: PRVSpacing.md) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(PRVRadius.shape(PRVRadius.md))
            .accessibilityLabel("Sign in with Apple")

            HStack(spacing: PRVSpacing.sm) {
                Rectangle().fill(Color.prv.separator).frame(height: 1)
                Text("or continue with email")
                    .prvStyle(.caption)
                    .fixedSize()
                Rectangle().fill(Color.prv.separator).frame(height: 1)
            }
            .accessibilityHidden(true)

            modePicker

            fields

            if let message = model.errorMessage {
                errorBanner(message)
            }

            Button {
                submit()
            } label: {
                if model.isWorking {
                    ProgressView()
                        .tint(Color.prv.textOnAccent)
                } else {
                    Text(model.mode.title)
                }
            }
            .buttonStyle(.prvPrimary)
            .disabled(!model.canSubmit)
            .accessibilityLabel(model.isWorking ? "Signing in" : model.mode.title)
        }
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
    }

    private var modePicker: some View {
        HStack(spacing: PRVSpacing.xxs) {
            ForEach(AuthModel.Mode.allCases) { mode in
                let isSelected = model.mode == mode
                Button {
                    model.select(mode)
                } label: {
                    Text(mode.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.prv.textOnAccent : Color.prv.textSecondary)
                        .padding(.vertical, PRVSpacing.xs)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.prv.accentGradient)
                                    .matchedGeometryEffect(id: "mode-indicator", in: modeIndicator)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(PRVSpacing.xxs)
        .background(Capsule().fill(Color.prv.surface.opacity(0.8)))
        .prvAnimation(PRVMotion.spring, value: model.mode)
    }

    @ViewBuilder
    private var fields: some View {
        VStack(spacing: PRVSpacing.sm) {
            if model.mode == .signUp {
                TextField("First name", text: $model.firstName)
                    .textContentType(.givenName)
                    .focused($focusedField, equals: .firstName)
                    .submitLabel(.next)
                    .authFieldChrome()

                TextField("Last name", text: $model.lastName)
                    .textContentType(.familyName)
                    .focused($focusedField, equals: .lastName)
                    .submitLabel(.next)
                    .authFieldChrome()
            }

            TextField("Email", text: $model.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .authFieldChrome()

            SecureField("Password", text: $model.password)
                .textContentType(model.mode == .signUp ? .newPassword : .password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .authFieldChrome()

            ForEach([model.namesIssue, model.emailIssue, model.passwordIssue].compactMap(\.self), id: \.self) { issue in
                Text(issue)
                    .foregroundStyle(Color.prv.danger)
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .disabled(model.isWorking)
        .onSubmit(advanceFocus)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.prv.danger)
            Text(message)
                .prvStyle(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PRVSpacing.sm)
        .background(PRVRadius.shape(PRVRadius.sm).fill(Color.prv.danger.opacity(0.12)))
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error. \(message)")
    }

    // MARK: - Guest entry

    private var guestEntry: some View {
        VStack(spacing: PRVSpacing.xs) {
            Button {
                PRVHaptics.tap()
                isShowingGuestSheet = true
            } label: {
                Label("Continue as Guest", systemImage: "eye")
            }
            .buttonStyle(.prvGlass)
            .accessibilityLabel("Continue as guest")
            .accessibilityHint("Browse salons without an account. Booking, chat, and rewards stay locked.")

            Text("Browse freely — booking, chat, and rewards unlock when you sign in.")
                .prvStyle(.footnote)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Actions

    private func submit() {
        focusedField = nil
        Task { await model.submitEmailForm(using: deps, session: session) }
    }

    private func advanceFocus() {
        switch focusedField {
        case .firstName: focusedField = .lastName
        case .lastName: focusedField = .email
        case .email: focusedField = .password
        case .password: submit()
        case nil: break
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken
            else {
                model.appleSignInMissingCredential()
                return
            }
            let fullName = credential.fullName
                .map { $0.formatted() }
                .flatMap { $0.isBlank ? nil : $0 }
            Task {
                await model.signInWithApple(
                    identityToken: identityToken,
                    fullName: fullName,
                    using: deps,
                    session: session
                )
            }
        case .failure(let error):
            model.appleSignInFailed(error)
        }
    }
}

// MARK: - Guest limits sheet

/// Explains exactly what guests can and cannot do before they start browsing,
/// so the unauthenticated experience never feels broken — just gated.
struct GuestLimitsSheet: View {
    /// Invoked when the user confirms they want to browse without an account.
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.lg) {
                Text("Browse as a Guest")
                    .prvStyle(.title2)

                Text("Take a look around — here's what opens up the moment you create a free account.")
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    capabilityRow("sparkle.magnifyingglass", "Explore salons, artists, and prices", available: true)
                    capabilityRow("star.fill", "Read verified reviews", available: true)
                    capabilityRow("calendar.badge.clock", "Book appointments", available: false)
                    capabilityRow("bubble.left.and.bubble.right.fill", "Chat with salons and the AI assistant", available: false)
                    capabilityRow("crown.fill", "Earn loyalty rewards", available: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .prvGlassCard()

                Button("Start Browsing") {
                    PRVHaptics.tap()
                    onContinue()
                }
                .buttonStyle(.prvPrimary)
                .accessibilityHint("Continues without an account.")

                Button("I'll sign in instead") {
                    dismiss()
                }
                .buttonStyle(.prvGlass)
            }
            .padding(PRVSpacing.xl)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func capabilityRow(_ symbol: String, _ text: String, available: Bool) -> some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: available ? "checkmark.circle.fill" : "lock.circle.fill")
                .foregroundStyle(available ? Color.prv.success : Color.prv.textSecondary)
            Image(systemName: symbol)
                .foregroundStyle(Color.prv.accent)
                .frame(width: PRVSpacing.xl)
            Text(text)
                .prvStyle(.callout)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text). \(available ? "Available as guest" : "Requires an account")")
    }
}

// MARK: - Field chrome

extension View {
    /// Shared chrome for auth form fields: comfortable padding on a soft
    /// surface with continuous corners.
    func authFieldChrome() -> some View {
        padding(PRVSpacing.md)
            .background(PRVRadius.shape(PRVRadius.md).fill(Color.prv.surface.opacity(0.85)))
    }
}

// MARK: - Previews

#Preview("Welcome — signed out") {
    AuthRootView()
        .environment(UserSession())
}

#Preview("Welcome — dark") {
    AuthRootView()
        .environment(UserSession())
        .preferredColorScheme(.dark)
}

#Preview("Guest limits sheet") {
    GuestLimitsSheet(onContinue: {})
        .environment(UserSession.previewClient)
}
