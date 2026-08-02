import SwiftUI
import PRVDesignSystem
import PRVModels
#if canImport(UIKit)
import UIKit
#endif

/// Per-kind delivery preferences, persisted in `UserDefaults` under stable
/// keys so SwiftUI's `@AppStorage` and non-UI code (the local reminder
/// scheduler, a future notification-service extension) read exactly the same
/// switches.
///
/// Every kind defaults to **on**: a user who has never opened this screen
/// still receives everything they opted into at the system level.
///
/// ```swift
/// if NotificationPreferences.isEnabled(.appointmentReminder) {
///     await NotificationScheduler.shared.scheduleReminders(for: appointment)
/// }
/// ```
public enum NotificationPreferences {
    /// Prefix shared by every per-kind key.
    public static let storagePrefix = "prv.notifications.enabled."

    /// The `UserDefaults` key backing one notification kind.
    /// - Parameter kind: The kind whose switch is being addressed.
    public static func storageKey(for kind: PRVNotification.Kind) -> String {
        storagePrefix + kind.rawValue
    }

    /// Whether the user allows this kind of notification.
    /// - Parameters:
    ///   - kind: The kind being checked.
    ///   - defaults: Store to read from; injectable for tests.
    /// - Returns: `true` unless the user explicitly turned the kind off.
    ///   Account and security notices (`.system`) are always enabled.
    public static func isEnabled(
        _ kind: PRVNotification.Kind,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard kind != .system else { return true }
        return defaults.object(forKey: storageKey(for: kind)) as? Bool ?? true
    }

    /// Turns one kind of notification on or off.
    public static func setEnabled(
        _ isEnabled: Bool,
        for kind: PRVNotification.Kind,
        in defaults: UserDefaults = .standard
    ) {
        guard kind != .system else { return }
        defaults.set(isEnabled, forKey: storageKey(for: kind))
    }

    /// Every kind the user currently allows.
    public static func enabledKinds(in defaults: UserDefaults = .standard) -> [PRVNotification.Kind] {
        PRVNotification.Kind.allCases.filter { isEnabled($0, in: defaults) }
    }

    /// Restores every switch to its default (on).
    public static func resetAll(in defaults: UserDefaults = .standard) {
        for kind in PRVNotification.Kind.allCases {
            defaults.removeObject(forKey: storageKey(for: kind))
        }
    }
}

// MARK: - Preferences sheet

/// The sheet presented from the notification centre toolbar: system
/// authorization status at the top, then a switch per notification kind.
struct NotificationPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var registrar = PushRegistrar()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AuthorizationBanner(
                        authorization: registrar.authorization,
                        allow: { Task { await registrar.requestFullAuthorization() } },
                        openSettings: { openSystemSettings() }
                    )
                    .listRowInsets(EdgeInsets(
                        top: PRVSpacing.xs,
                        leading: PRVSpacing.md,
                        bottom: PRVSpacing.xs,
                        trailing: PRVSpacing.md
                    ))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(PRVNotification.Kind.configurableCases, id: \.self) { kind in
                        NotificationKindToggle(kind: kind)
                    }
                } header: {
                    Text("What you receive")
                        .prvStyle(.footnote)
                        .textCase(nil)
                } footer: {
                    Text("Account and security notices are always delivered. Everything else can be silenced without leaving the app.")
                        .prvStyle(.caption)
                }

                Section {
                    Button {
                        PRVHaptics.tap()
                        openSystemSettings()
                    } label: {
                        PRVListRow(
                            title: "System Settings",
                            subtitle: "Sounds, banners, Focus, and Summary",
                            systemImage: "gear",
                            tint: Color.prv.textSecondary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open notification settings in the Settings app")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.prv.canvas)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        PRVHaptics.tap()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                }
            }
            .task { await registrar.refreshAuthorization() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Opens this app's page in the Settings app, where system-level delivery
    /// (banners, sounds, Focus) is configured.
    private func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
        #endif
    }
}

/// One switch, backed directly by `@AppStorage` so the toggle and the
/// scheduler never disagree about what is enabled.
private struct NotificationKindToggle: View {
    @AppStorage private var isEnabled: Bool

    private let kind: PRVNotification.Kind

    init(kind: PRVNotification.Kind) {
        self.kind = kind
        _isEnabled = AppStorage(
            wrappedValue: true,
            NotificationPreferences.storageKey(for: kind)
        )
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: PRVSpacing.sm) {
                PRVListRowIcon(systemImage: kind.symbolName, tint: kind.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                    Text(kind.preferenceDetail)
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Color.prv.accent)
        .onChange(of: isEnabled) { _, newValue in
            PRVHaptics.tap()
            // Silencing appointment reminders must also clear the local
            // reminders already sitting in the notification queue.
            if kind == .appointmentReminder, !newValue {
                Task { await NotificationScheduler.shared.cancelAllReminders() }
            }
        }
        .accessibilityLabel(kind.displayName)
        .accessibilityHint(kind.preferenceDetail)
    }
}

/// Explains the system-level authorization state and offers the one action
/// that can change it.
private struct AuthorizationBanner: View {
    let authorization: PushRegistrar.Authorization
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        PRVGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md) {
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                Image(systemName: symbolName)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.prv.textPrimary)
                    Text(message)
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)

                    if let actionTitle {
                        Button(actionTitle) {
                            PRVHaptics.impact()
                            switch authorization {
                            case .notDetermined, .provisional: allow()
                            case .denied: openSettings()
                            case .authorized: break
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                        .padding(.top, PRVSpacing.xxs)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }

    private var symbolName: String {
        switch authorization {
        case .authorized: "bell.badge.fill"
        case .provisional: "bell.and.waves.left.and.right.fill"
        case .notDetermined: "bell.fill"
        case .denied: "bell.slash.fill"
        }
    }

    private var tint: Color {
        switch authorization {
        case .authorized: Color.prv.success
        case .provisional: Color.prv.accent
        case .notDetermined: Color.prv.accent
        case .denied: Color.prv.warning
        }
    }

    private var title: String {
        switch authorization {
        case .authorized: "Notifications are on"
        case .provisional: "Delivering quietly"
        case .notDetermined: "Turn on notifications"
        case .denied: "Notifications are off"
        }
    }

    private var message: String {
        switch authorization {
        case .authorized:
            "You'll hear about reminders, confirmations, and waitlist openings the moment they happen."
        case .provisional:
            "Alerts arrive silently in Notification Centre. Allow banners so you never miss a slot opening."
        case .notDetermined:
            "Reminders before your visit, and a ping the instant a waitlist slot frees up."
        case .denied:
            "Notifications are disabled for PRV Beauty in Settings. Reminders will still appear inside the app."
        }
    }

    private var actionTitle: String? {
        switch authorization {
        case .authorized: nil
        case .provisional: "Allow Banners"
        case .notDetermined: "Allow Notifications"
        case .denied: "Open Settings"
        }
    }
}

// MARK: - Previews

#Preview("Notification Preferences") {
    NotificationPreferencesSheet()
}

#Preview("Notification Preferences — Dark") {
    NotificationPreferencesSheet()
        .preferredColorScheme(.dark)
}
