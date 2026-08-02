import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Suggestion

/// A campaign idea derived on device from the salon's own numbers.
///
/// Suggestions never act on their own: each one carries a prefilled
/// ``CampaignDraft`` that only reaches the marketing repository if someone taps
/// "Create campaign" and saves the composer.
struct MarketingSuggestion: Identifiable, Sendable {
    /// Stable across recomputes so the list doesn't thrash.
    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let tint: Color
    /// Prefills the composer when the suggestion is accepted.
    let draft: CampaignDraft
}

// MARK: - Engine

/// Turns an analytics snapshot into at most three concrete campaign ideas.
///
/// Everything is computed locally from `DashboardSnapshot` — no data leaves the
/// device and no model is called. The rules are deliberately legible so an
/// owner can see why each idea was offered:
///
/// 1. **Quiet day** — the weekday with the lowest average revenue in the window
///    (skipping days the salon is closed) gets a targeted promotion.
/// 2. **Win-back** — when retention drops below 85%, lapsed clients get an
///    invitation back.
/// 3. **Birthday** — a standing automation, offered until one exists.
enum MarketingSuggestionEngine {
    static func suggestions(
        snapshot: DashboardSnapshot?,
        salon: Salon?,
        currency: Currency,
        existingCampaigns: [Campaign]
    ) -> [MarketingSuggestion] {
        guard let snapshot else { return [] }
        var result: [MarketingSuggestion] = []
        if let quiet = quietDaySuggestion(snapshot: snapshot, salon: salon, currency: currency) {
            result.append(quiet)
        }
        if let winBack = winBackSuggestion(snapshot: snapshot, salon: salon) {
            result.append(winBack)
        }
        if let birthday = birthdaySuggestion(salon: salon, existingCampaigns: existingCampaigns) {
            result.append(birthday)
        }
        return result
    }

    // MARK: Quiet day

    /// Finds the weekday that earns least and proposes filling it.
    private static func quietDaySuggestion(
        snapshot: DashboardSnapshot,
        salon: Salon?,
        currency: Currency
    ) -> MarketingSuggestion? {
        let calendar = Calendar.current
        let openWeekdays = openWeekdays(for: salon)

        var totals: [Int: (sum: Decimal, count: Int)] = [:]
        for point in snapshot.revenueSeries {
            let weekday = calendar.component(.weekday, from: point.date)
            guard openWeekdays.isEmpty || openWeekdays.contains(weekday) else { continue }
            let current = totals[weekday] ?? (0, 0)
            totals[weekday] = (current.sum + point.value, current.count + 1)
        }

        let averages = totals.compactMapValues { entry -> Decimal? in
            guard entry.count > 0 else { return nil }
            return entry.sum / Decimal(entry.count)
        }
        guard averages.count > 1,
              let quietest = averages.min(by: { $0.value < $1.value }),
              let busiest = averages.max(by: { $0.value < $1.value }),
              quietest.key != busiest.key
        else { return nil }

        let dayName = weekdayName(quietest.key, calendar: calendar)
        let salonName = salon?.name ?? "the studio"
        let gap = busiest.value - quietest.value
        let quietAverage = Money(quietest.value.rounded(), currency)
        let gapMoney = Money(gap.rounded(), currency)

        let message = "\(dayName)s are calm at \(salonName). Book any treatment this \(dayName) "
            + "and take 15% off with a little extra time in the chair."

        return MarketingSuggestion(
            id: "quiet-day",
            title: "Fill your quiet \(dayName)",
            detail: "\(dayName)s average \(quietAverage.formatted) — \(gapMoney.formatted) below your best day. "
                + "A one-day offer is the cheapest way to level the week.",
            symbolName: "calendar.badge.exclamationmark",
            tint: Color.prv.accent,
            draft: CampaignDraft(
                name: "\(dayName) Treat",
                kind: .promotion,
                channels: [.push, .email],
                message: message,
                isScheduled: true,
                scheduledAt: nextMorning(matching: quietest.key, calendar: calendar),
                id: "suggestion-quiet-day"
            )
        )
    }

    // MARK: Win-back

    /// Proposes reaching out when repeat business slips.
    private static func winBackSuggestion(
        snapshot: DashboardSnapshot,
        salon: Salon?
    ) -> MarketingSuggestion? {
        guard snapshot.retentionRate > 0, snapshot.retentionRate < MarketingRules.retentionThreshold else { return nil }
        let salonName = salon?.name ?? "us"
        let missing = max(0, MarketingRules.retentionThreshold - snapshot.retentionRate)

        let message = "We've missed you at \(salonName). Come back this month and your next "
            + "appointment is 20% off — your stylist already has your notes."

        return MarketingSuggestion(
            id: "win-back",
            title: "Win back lapsed clients",
            detail: "Retention is \(OperationsFormat.percent(snapshot.retentionRate)), "
                + "\(OperationsFormat.percent(missing)) under a healthy 85%. "
                + "\(OperationsFormat.integer(snapshot.newClientCount)) new clients arrived this period — keep them.",
            symbolName: "arrow.uturn.backward.circle.fill",
            tint: Color.prv.warning,
            draft: CampaignDraft(
                name: "We Miss You",
                kind: .winBack,
                channels: [.email, .push],
                message: message,
                id: "suggestion-win-back"
            )
        )
    }

    // MARK: Birthday

    /// Offers the standing birthday automation until one is set up.
    private static func birthdaySuggestion(
        salon: Salon?,
        existingCampaigns: [Campaign]
    ) -> MarketingSuggestion? {
        guard !existingCampaigns.contains(where: { $0.kind == .birthday }) else { return nil }
        let salonName = salon?.name ?? "the studio"

        let message = "Happy birthday! There's a little something waiting for you at \(salonName) — "
            + "book any treatment this month and your gift is on us."

        return MarketingSuggestion(
            id: "birthday",
            title: "Turn on birthday wishes",
            detail: "A birthday message is the highest-opening thing a salon sends, and it runs itself once. "
                + "You don't have one yet.",
            symbolName: "gift.fill",
            tint: Color.prv.gold,
            draft: CampaignDraft(
                name: "Birthday Gift",
                kind: .birthday,
                channels: [.push, .email],
                message: message,
                id: "suggestion-birthday"
            )
        )
    }

    // MARK: Helpers

    /// Weekdays the salon actually opens, empty when hours aren't configured.
    private static func openWeekdays(for salon: Salon?) -> Set<Int> {
        guard let salon, !salon.openingHours.isEmpty else { return [] }
        return Set(salon.openingHours.filter { !$0.isClosed }.map(\.weekday))
    }

    /// Localized standalone weekday name, e.g. `Tuesday`.
    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let symbols = calendar.standaloneWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "That day" }
        return symbols[index]
    }

    /// The next occurrence of a weekday at 10:00, which is when a salon's
    /// audience is most likely to read a promotion.
    private static func nextMorning(matching weekday: Int, calendar: Calendar) -> Date {
        let next = calendar.nextDate(
            after: .now,
            matching: DateComponents(weekday: weekday),
            matchingPolicy: .nextTime
        ) ?? Date.now.adding(days: 1, calendar: calendar)
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: next) ?? next
    }
}

// MARK: - Card

/// The suggestions block: up to three ideas, each with a one-tap composer.
struct MarketingSuggestionsCard: View {
    let suggestions: [MarketingSuggestion]
    let errorMessage: String?
    /// Whether the session holds `.manageMarketing`.
    let canCreate: Bool
    let create: (MarketingSuggestion) -> Void
    let retry: () -> Void

    var body: some View {
        OperationsBlock(
            "Suggestions",
            subtitle: "Worked out on device from your own numbers"
        ) {
            if let errorMessage {
                OperationsErrorCard(message: errorMessage, retry: retry)
            } else if suggestions.isEmpty {
                Text("Nothing to suggest right now — your week is balanced and your automations are covered. Nicely run.")
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .prvGlassCard()
            } else {
                VStack(spacing: PRVSpacing.md) {
                    ForEach(suggestions) { suggestion in
                        SuggestionRow(
                            suggestion: suggestion,
                            canCreate: canCreate,
                            create: { create(suggestion) }
                        )
                        if suggestion.id != suggestions.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }

                    OperationsFootnote(
                        "Suggestions are computed from the last \(MarketingRules.insightWindowDays) days of your own reporting. Nothing is sent until you save a campaign.",
                        systemImage: "sparkles"
                    )
                }
                .prvGlassCard()
            }
        }
    }
}

/// One suggestion: glyph, headline, reasoning, and the accept action.
private struct SuggestionRow: View {
    let suggestion: MarketingSuggestion
    let canCreate: Bool
    let create: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: suggestion.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(suggestion.tint)
                .frame(width: 40, height: 40)
                .background(suggestion.tint.opacity(0.12), in: PRVRadius.shape(PRVRadius.md))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text(suggestion.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(suggestion.detail)
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)

                if canCreate {
                    Button {
                        create()
                    } label: {
                        Label("Create campaign", systemImage: "plus.circle")
                            .font(.footnote.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.prv.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Create a campaign from: \(suggestion.title)")
                    .accessibilityHint("Opens the composer prefilled with this idea")
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Previews

#Preview("Suggestions") {
    ScrollView {
        MarketingSuggestionsCard(
            suggestions: MarketingSuggestionEngine.suggestions(
                snapshot: DashboardSnapshot(
                    salonID: PreviewData.salonLumiere.id,
                    periodStart: Date.now.adding(days: -30),
                    periodEnd: .now,
                    revenue: Money(18_400),
                    newClientCount: 14,
                    retentionRate: 0.79,
                    revenueSeries: (0 ..< 28).map { offset in
                        MetricPoint(
                            date: Date.now.adding(days: -offset),
                            value: [640, 720, 580, 810, 940, 1_260, 380][offset % 7]
                        )
                    }
                ),
                salon: PreviewData.salonLumiere,
                currency: .eur,
                existingCampaigns: []
            ),
            errorMessage: nil,
            canCreate: true,
            create: { _ in },
            retry: {}
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}
