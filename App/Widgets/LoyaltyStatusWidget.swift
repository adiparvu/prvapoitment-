import SwiftUI
import WidgetKit
import PRVDesignSystem
import PRVModels

/// Loyalty standing at a glance: a progress ring on the Lock Screen
/// (`accessoryCircular`) and a full tier card on the Home Screen
/// (`systemSmall`).
///
/// Like every PRV widget it renders from the shared app-group snapshot, so it
/// stays correct offline and costs nothing to refresh.
struct LoyaltyStatusWidget: Widget {
    /// Kind identifier; also the key WidgetKit reloads by.
    static let kind = "com.prv.beauty.widget.loyalty"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LoyaltyStatusProvider()) { entry in
            LoyaltyStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Loyalty Status")
        .description("Your tier, XP, and progress to the next reward.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

// MARK: - Timeline

/// One rendered moment of the loyalty widget.
struct LoyaltyStatusEntry: TimelineEntry {
    let date: Date
    let loyalty: PRVWidgetSnapshot.Loyalty?

    /// Entry used for the redacted placeholder and previews.
    static let placeholder = LoyaltyStatusEntry(
        date: .now,
        loyalty: PRVWidgetSnapshot.preview.loyalty
    )

    /// Entry for a signed-out client, or before the first snapshot exists.
    static let empty = LoyaltyStatusEntry(date: .now, loyalty: nil)
}

/// Loyalty changes only when the client earns XP, so the timeline is a single
/// entry refreshed on a relaxed cadence — the app force-reloads timelines the
/// moment it writes a new snapshot.
struct LoyaltyStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> LoyaltyStatusEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (LoyaltyStatusEntry) -> Void) {
        completion(context.isPreview ? .placeholder : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LoyaltyStatusEntry>) -> Void) {
        let entry = currentEntry()
        completion(
            Timeline(
                entries: [entry],
                policy: .after(entry.date.addingTimeInterval(60 * 60 * 4))
            )
        )
    }

    private func currentEntry(at now: Date = .now) -> LoyaltyStatusEntry {
        LoyaltyStatusEntry(date: now, loyalty: PRVWidgetSnapshot.load()?.loyalty)
    }
}

// MARK: - Views

/// Routes to the right layout for the widget family.
struct LoyaltyStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: LoyaltyStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            LoyaltyAccessoryRing(loyalty: entry.loyalty)
                .prvAccessoryBackground()
                .widgetURL(PRVDeepLink.loyalty)
        default:
            LoyaltyTierCard(loyalty: entry.loyalty)
                .prvWidgetBackground()
                .widgetURL(PRVDeepLink.loyalty)
        }
    }
}

/// Lock Screen complication: a capacity ring around the tier's initial.
///
/// Accessory widgets are rendered monochrome by the system, so the design
/// leans on shape and the tier glyph rather than colour, and marks itself
/// accentable so the tinted-ring treatment lands on the right element.
struct LoyaltyAccessoryRing: View {
    let loyalty: PRVWidgetSnapshot.Loyalty?

    private var tier: LoyaltyTier { loyalty?.tier ?? .bronze }
    private var progress: Double { loyalty?.progress ?? 0 }

    var body: some View {
        Gauge(value: progress, in: 0...1) {
            Image(systemName: tier.widgetSymbolName)
        } currentValueLabel: {
            Image(systemName: tier.widgetSymbolName)
                .font(.system(size: 15, weight: .semibold))
                .widgetAccentable()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tier.displayName) tier")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let loyalty else { return "No loyalty data yet" }
        guard let next = loyalty.nextTier else { return "Top tier reached" }
        let percent = progress.formatted(.percent.precision(.fractionLength(0)))
        return "\(percent) toward \(next.displayName)"
    }
}

/// systemSmall: the brand ring with the tier emblem, the tier name, and how
/// much XP is left before the next one.
struct LoyaltyTierCard: View {
    let loyalty: PRVWidgetSnapshot.Loyalty?

    var body: some View {
        if let loyalty {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                HStack(alignment: .top, spacing: PRVSpacing.xs) {
                    PRVProgressRing(
                        progress: loyalty.progress,
                        lineWidth: 6,
                        size: 48,
                        tint: loyalty.tier.widgetTint
                    ) {
                        Image(systemName: loyalty.tier.widgetSymbolName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(loyalty.tier.widgetTint)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(loyalty.spendablePoints)")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("points")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                Text(loyalty.tier.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(progressCaption(loyalty))
                    .font(.caption2)
                    .foregroundStyle(Color.prv.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loyalty status")
            .accessibilityValue(
                "\(loyalty.tier.displayName) tier, \(loyalty.spendablePoints) points. \(progressCaption(loyalty))"
            )
        } else {
            PRVWidgetPlaceholder(
                systemImage: "crown.fill",
                title: "Start earning",
                message: "Book a treatment to begin your rewards journey."
            )
        }
    }

    private func progressCaption(_ loyalty: PRVWidgetSnapshot.Loyalty) -> String {
        guard let next = loyalty.nextTier, let remaining = loyalty.xpToNextTier, remaining > 0 else {
            return "\(loyalty.xp.formatted()) XP · top tier reached"
        }
        return "\(remaining.formatted()) XP to \(next.displayName)"
    }
}

// MARK: - Previews

#Preview("Loyalty — Circular", as: .accessoryCircular) {
    LoyaltyStatusWidget()
} timeline: {
    LoyaltyStatusEntry.placeholder
    LoyaltyStatusEntry.empty
}

#Preview("Loyalty — Small", as: .systemSmall) {
    LoyaltyStatusWidget()
} timeline: {
    LoyaltyStatusEntry.placeholder
    LoyaltyStatusEntry.empty
}
