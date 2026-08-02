import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Campaign card

/// One campaign in the list: what it is, where it goes, and how it performed.
struct CampaignCard: View {
    let campaign: Campaign
    /// The attached coupon, when one is set.
    let coupon: Coupon?
    let currency: Currency
    /// Whether the session holds `.manageMarketing`.
    let canEdit: Bool
    let edit: () -> Void

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                header
                channelRow
                if !campaign.message.isBlank {
                    Text(campaign.message)
                        .prvStyle(.footnote)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Color.prv.separator.opacity(0.5))
                stats
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canEdit else { return }
            edit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Edit campaign")) {
            guard canEdit else { return }
            edit()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: campaign.kind.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.prv.textOnAccent)
                .frame(width: 40, height: 40)
                .background(Color.prv.accentGradient, in: PRVRadius.shape(PRVRadius.md))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(campaign.name)
                    .prvStyle(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            OperationsStatusPill(title: campaign.status.displayName, tint: campaign.status.tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let scheduledAt = campaign.scheduledAt {
            return "\(campaign.kind.displayName) · \(OperationsFormat.dateTime(scheduledAt))"
        }
        return campaign.kind.displayName
    }

    private var channelRow: some View {
        PRVFlowLayout(spacing: PRVSpacing.xxs) {
            ForEach(campaign.channels, id: \.self) { channel in
                PRVTag(channel.displayName, systemImage: channel.symbolName, tint: Color.prv.accent)
            }
            if let coupon {
                PRVTag("\(coupon.code) · \(coupon.discountSummary)", systemImage: "ticket", tint: Color.prv.gold)
            }
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: PRVSpacing.md) {
            statColumn("Sent", OperationsFormat.integer(campaign.sentCount))
            statColumn("Opens", openRateText)
            statColumn("Booked", OperationsFormat.integer(campaign.bookingCount))
            statColumn("Revenue", OperationsFormat.compactCurrency(revenue))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statsAccessibilityLabel)
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .prvStyle(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var revenue: Money {
        Money(campaign.attributedRevenue.amount, currency)
    }

    private var openRateText: String {
        guard campaign.sentCount > 0 else { return "—" }
        return OperationsFormat.percent(Double(campaign.openCount) / Double(campaign.sentCount))
    }

    private var statsAccessibilityLabel: String {
        var label = "\(OperationsFormat.integer(campaign.sentCount)) sent, "
        label += campaign.sentCount > 0 ? "\(openRateText) opened, " : "not sent yet, "
        label += "\(OperationsFormat.integer(campaign.bookingCount)) bookings, "
        label += "\(revenue.formatted) attributed."
        return label
    }
}

// MARK: - Lock screen preview

/// A faithful mock of how a push lands on the Lock Screen, shown live in the
/// composer so copy is written against the real shape rather than a text box.
struct LockScreenPushPreview: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let salonName: String
    let message: String

    var body: some View {
        VStack(spacing: PRVSpacing.xs) {
            Text(Date.now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: PRVSpacing.xs) {
                appIcon

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: PRVSpacing.xxs) {
                        Text("PRV BEAUTY")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.prv.textSecondary)
                            .textCase(.uppercase)
                        Spacer(minLength: PRVSpacing.xxs)
                        Text("now")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary)
                    }

                    Text(salonName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)

                    Text(message.isBlank ? "Your message appears here." : message)
                        .font(.footnote)
                        .foregroundStyle(message.isBlank ? Color.prv.textSecondary : Color.prv.textPrimary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(PRVSpacing.sm)
            .background {
                if reduceTransparency {
                    PRVRadius.shape(PRVRadius.md).fill(Color.prv.surfaceElevated)
                } else {
                    PRVRadius.shape(PRVRadius.md).fill(.regularMaterial)
                }
            }
            .overlay {
                PRVRadius.shape(PRVRadius.md)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
        }
        .padding(PRVSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.prv.accent.opacity(0.35), Color.prv.gold.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: PRVRadius.shape(PRVRadius.lg)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Lock screen preview. From \(salonName): \(message.isBlank ? "your message appears here" : message)"
        )
    }

    private var appIcon: some View {
        Image(systemName: "sparkles")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.prv.textOnAccent)
            .frame(width: 24, height: 24)
            .background(Color.prv.accentGradient, in: PRVRadius.shape(6))
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Campaign card") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            CampaignCard(
                campaign: Campaign(
                    salonID: PreviewData.salonLumiere.id,
                    name: "Autumn Gloss Refresh",
                    kind: .promotion,
                    channels: [.push, .email],
                    message: "Your colour deserves a gloss before the season turns. 15% off all gloss services this month.",
                    status: .running,
                    scheduledAt: Date.now.addingTimeInterval(-86_400 * 2),
                    sentCount: 1_240,
                    openCount: 486,
                    bookingCount: 37,
                    attributedRevenue: Money(4_180)
                ),
                coupon: Coupon(
                    salonID: PreviewData.salonLumiere.id,
                    code: "GLOSS15",
                    discount: .percent(15)
                ),
                currency: .eur,
                canEdit: true,
                edit: {}
            )

            LockScreenPushPreview(
                salonName: "Maison Lumière",
                message: "Tuesdays are calm at Maison Lumière. Book any treatment this Tuesday and take 15% off."
            )
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}
