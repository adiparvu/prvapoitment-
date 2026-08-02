import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Presented when a day is fully booked: the client picks the window they
/// could come in, and the salon notifies them the moment it opens up.
struct WaitlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The service the client is waiting for.
    let serviceName: String
    /// The artist preference, when one was chosen.
    let professionalName: String?
    /// The day the client was browsing.
    let day: Date
    /// Whether a join request is in flight.
    let isJoining: Bool
    /// Submits the window. Returns `true` when the entry was accepted.
    let join: @MainActor (Date, Date) async -> Bool

    @State private var earliest: Date
    @State private var latest: Date

    /// Creates the sheet with a sensible default window across the given day.
    init(
        serviceName: String,
        professionalName: String?,
        day: Date,
        isJoining: Bool,
        join: @escaping @MainActor (Date, Date) async -> Bool
    ) {
        self.serviceName = serviceName
        self.professionalName = professionalName
        self.day = day
        self.isJoining = isJoining
        self.join = join
        let start = day.startOfDay()
        _earliest = State(initialValue: start.adding(minutes: 9 * 60))
        _latest = State(initialValue: start.adding(minutes: 19 * 60))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    header

                    PRVGlassCard {
                        VStack(alignment: .leading, spacing: PRVSpacing.md) {
                            DatePicker(
                                "Earliest",
                                selection: $earliest,
                                in: windowRange,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            Divider()
                            DatePicker(
                                "Latest",
                                selection: $latest,
                                in: windowRange,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                        .tint(Color.prv.accent)
                        .font(.subheadline.weight(.medium))
                    }

                    PRVGlassCard {
                        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                            BookingSummaryRow(
                                label: "Treatment",
                                value: serviceName,
                                systemImage: "sparkles"
                            )
                            BookingSummaryRow(
                                label: "Artist",
                                value: professionalName ?? "Any available",
                                systemImage: "person.crop.circle"
                            )
                            BookingSummaryRow(
                                label: "Window",
                                value: windowSummary,
                                systemImage: "clock.arrow.2.circlepath"
                            )
                        }
                    }

                    Text("Waitlist spots are offered in order. You'll get a notification with a short window to accept.")
                        .prvStyle(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PRVSpacing.md)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Join the Waitlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .prvBottomBar {
                Button {
                    submit()
                } label: {
                    if isJoining {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Join the Waitlist")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(isJoining)
                .accessibilityLabel("Join the waitlist")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: PRVSpacing.md) {
            Image(systemName: "hourglass")
                .font(.title2)
                .foregroundStyle(Color.prv.accentGradient)
                .frame(width: 48, height: 48)
                .background(Color.prv.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text("Tell us when you could come in on \(BookingFormatting.shortDay(day)) and we'll hold your place in line.")
                .prvStyle(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The window is confined to the browsed day plus the following week, so
    /// clients cannot accidentally waitlist themselves into next season.
    private var windowRange: ClosedRange<Date> {
        let start = max(day.startOfDay(), Date.now)
        let end = day.startOfDay().adding(days: 7)
        return start...max(end, start.addingTimeInterval(3_600))
    }

    private var windowSummary: String {
        "\(BookingFormatting.time(min(earliest, latest))) – \(BookingFormatting.time(max(earliest, latest)))"
    }

    private func submit() {
        PRVHaptics.impact()
        let from = min(earliest, latest)
        let to = max(earliest, latest)
        Task {
            if await join(from, to) {
                dismiss()
            }
        }
    }
}
