import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// The personal time clock.
///
/// One large glass button toggles the signed-in professional between on and
/// off the clock. Clocking asks Core Location for a single fix and hands the
/// coordinate to the team repository, which validates it against the salon's
/// geofence — a validated entry earns the shield badge. While on the clock the
/// card runs a live stopwatch driven by a `TimelineView`, so only the numerals
/// redraw each second.
struct ClockInCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The person the clock belongs to, or `nil` when the signed-in account
    /// isn't linked to an employment record.
    let member: TeamMember?
    /// The open entry, when they are already clocked in.
    let activeEntry: TimeEntry?
    /// Hours logged since Monday.
    let hoursThisWeek: TimeInterval
    /// Whether a clock round trip is in flight.
    let isBusy: Bool
    /// Why the last entry wasn't GPS-verified, when that happened.
    let locationNotice: String?
    let dismissNotice: () -> Void
    let toggle: () -> Void

    private var isClockedIn: Bool { activeEntry != nil }

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(spacing: PRVSpacing.md) {
                header

                if member == nil {
                    unlinkedState
                } else {
                    clockButton
                    statusLine
                    if let locationNotice {
                        noticeRow(locationNotice)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .prvAnimation(PRVMotion.gentle, value: isClockedIn)
        .prvAnimation(PRVMotion.spring, value: locationNotice)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: PRVSpacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time Clock")
                    .prvStyle(.headline)
                Text(member?.displayName ?? "Not linked")
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            if let activeEntry, activeEntry.gpsValidated {
                Label("GPS verified", systemImage: "checkmark.shield.fill")
                    .font(.caption2.weight(.bold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.prv.success)
                    .padding(.vertical, 4)
                    .padding(.horizontal, PRVSpacing.xs)
                    .background(Color.prv.success.opacity(0.14), in: Capsule())
                    .accessibilityLabel("This shift is GPS verified")
            } else if isClockedIn {
                Label("Not verified", systemImage: "shield.slash")
                    .font(.caption2.weight(.bold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.prv.textSecondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, PRVSpacing.xs)
                    .background(Color.prv.surface, in: Capsule())
                    .accessibilityLabel("This shift is not GPS verified")
            }
        }
    }

    // MARK: Button

    private var clockButton: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 168, height: 168)

                if isClockedIn {
                    Circle()
                        .fill(Color.prv.accentGradient)
                        .frame(width: 168, height: 168)
                }

                Circle()
                    .strokeBorder(
                        isClockedIn ? Color.prv.textOnAccent.opacity(0.35) : Color.prv.accent.opacity(0.45),
                        lineWidth: 1.5
                    )
                    .frame(width: 168, height: 168)

                VStack(spacing: PRVSpacing.xxs) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.large)
                            .tint(isClockedIn ? Color.prv.textOnAccent : Color.prv.accent)
                    } else {
                        Image(systemName: isClockedIn ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(isClockedIn ? Color.prv.textOnAccent : Color.prv.accent)
                    }

                    Text(isClockedIn ? "Clock Out" : "Clock In")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(isClockedIn ? Color.prv.textOnAccent : Color.prv.textPrimary)

                    if let activeEntry {
                        elapsedLabel(since: activeEntry.clockIn)
                    } else {
                        Text("Tap to start your shift")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 140)
                .padding(PRVSpacing.sm)
            }
            .prvSoftShadow()
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(isClockedIn ? "Clock out" : "Clock in")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Uses your location once to verify you are at the salon")
        .accessibilityAddTraits(.isButton)
    }

    /// The live stopwatch. Only this label re-renders every second.
    private func elapsedLabel(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(OperationsFormat.stopwatch(context.date.timeIntervalSince(start)))
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.prv.textOnAccent)
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .accessibilityHidden(true)
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: PRVSpacing.xs) {
            if let activeEntry {
                PRVTag("Since \(OperationsFormat.time(activeEntry.clockIn))", systemImage: "clock.badge.checkmark")
            } else {
                PRVTag("Off the clock", systemImage: "moon.zzz")
            }
            PRVTag("\(OperationsFormat.duration(hoursThisWeek)) this week", systemImage: "calendar.badge.clock")
        }
    }

    private var accessibilityValue: String {
        guard let activeEntry else {
            return "Off the clock. \(OperationsFormat.duration(hoursThisWeek)) logged this week."
        }
        return "On the clock since \(OperationsFormat.time(activeEntry.clockIn)), "
            + "\(OperationsFormat.duration(activeEntry.elapsed())) so far."
    }

    // MARK: Notice

    private func noticeRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "location.slash")
                .font(.caption)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)

            Text(message)
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: PRVSpacing.xxs)

            Button {
                PRVHaptics.tap()
                dismissNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.prv.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss location notice")
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.warning.opacity(0.10), in: PRVRadius.shape(PRVRadius.md))
    }

    // MARK: Unlinked

    private var unlinkedState: some View {
        VStack(spacing: PRVSpacing.xs) {
            Image(systemName: "person.badge.clock")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.prv.accentGradient)
                .padding(PRVSpacing.md)
                .background(Color.prv.accent.opacity(0.08), in: Circle())
                .accessibilityHidden(true)

            Text("Time tracking is linked to your team profile")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .multilineTextAlignment(.center)

            Text("Your account isn't connected to an employment record at this salon yet. An owner or manager can link it, and your clock will appear here.")
                .prvStyle(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - History

/// One row of the time-entry history: window, duration, and GPS validation.
struct TimeEntryRow: View {
    let entry: TimeEntry

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: entry.isOpen ? "clock.badge.fill" : "clock")
                .font(.body)
                .foregroundStyle(entry.isOpen ? Color.prv.accent : Color.prv.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(OperationsFormat.date(entry.clockIn))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(window)
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            if entry.gpsValidated {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(Color.prv.success)
                    .accessibilityHidden(true)
            }

            Text(OperationsFormat.duration(entry.elapsed()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var window: String {
        guard let clockOut = entry.clockOut else {
            return "From \(OperationsFormat.time(entry.clockIn)) · still running"
        }
        return OperationsFormat.window(entry.clockIn, clockOut)
    }

    private var accessibilityLabel: String {
        var label = "\(OperationsFormat.date(entry.clockIn)), \(window), "
        label += "\(OperationsFormat.duration(entry.elapsed()))."
        label += entry.gpsValidated ? " GPS verified." : ""
        return label
    }
}

// MARK: - Previews

/// Deterministic fixtures for the time-clock previews. The in-memory backend
/// seeds employment records without a linked account, so the previews build
/// their own linked member to exercise every state of the card.
enum TeamPreviewFixtures {
    static let employee = Employee(
        salonID: PreviewData.salonLumiere.id,
        professionalID: PreviewData.stylistAmelie.id,
        userID: PreviewData.owner.id,
        compensation: .hybrid,
        monthlySalary: Money(2_400),
        commissionPercent: 15,
        vacationDaysUsed: 12
    )

    static var member: TeamMember {
        TeamMember(employee: employee, professional: PreviewData.stylistAmelie, goals: [])
    }
}

#Preview("Time clock") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            ClockInCard(
                member: TeamPreviewFixtures.member,
                activeEntry: TimeEntry(
                    employeeID: TeamPreviewFixtures.employee.id,
                    clockIn: Date.now.addingTimeInterval(-3 * 3_600 - 742),
                    clockInLocation: PreviewData.salonLumiere.address.coordinate,
                    gpsValidated: true
                ),
                hoursThisWeek: 27.5 * 3_600,
                isBusy: false,
                locationNotice: nil,
                dismissNotice: {},
                toggle: {}
            )

            ClockInCard(
                member: TeamPreviewFixtures.member,
                activeEntry: nil,
                hoursThisWeek: 6 * 3_600,
                isBusy: false,
                locationNotice: "Location is off, so this entry isn't GPS-verified. Enable location in Settings to verify future ones.",
                dismissNotice: {},
                toggle: {}
            )

            ClockInCard(
                member: nil,
                activeEntry: nil,
                hoursThisWeek: 0,
                isBusy: false,
                locationNotice: nil,
                dismissNotice: {},
                toggle: {}
            )
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}
