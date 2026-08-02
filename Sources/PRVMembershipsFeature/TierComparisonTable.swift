import SwiftUI
import PRVDesignSystem
import PRVModels

/// A tier-by-benefit comparison table: one column per tier on sale, one row
/// per benefit category, checkmarks (or headline figures) in the cells.
///
/// Built on `Grid` so columns stay aligned at every Dynamic Type size, and
/// wrapped in a horizontal scroll view so four tiers never squash the labels
/// on a small phone. The matrix itself is precomputed in the screen model —
/// `body` only draws.
struct TierComparisonTable: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The precomputed matrix.
    let matrix: TierComparisonMatrix

    /// Width of the benefit-label column.
    private let labelWidth: CGFloat = 148
    /// Width of each tier column.
    private let columnWidth: CGFloat = 78

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: PRVSpacing.sm) {
                headerRow

                ForEach(matrix.rows) { row in
                    Divider().overlay(Color.prv.separator.opacity(0.5))
                    benefitRow(row)
                }
            }
            .padding(PRVSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background {
            if reduceTransparency {
                PRVRadius.shape(PRVRadius.lg).fill(Color.prv.surface)
            } else {
                PRVRadius.shape(PRVRadius.lg).fill(.ultraThinMaterial)
            }
        }
        .clipShape(PRVRadius.shape(PRVRadius.lg))
        .overlay {
            PRVRadius.shape(PRVRadius.lg)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .prvSoftShadow()
    }

    // MARK: Rows

    private var headerRow: some View {
        GridRow {
            Text("Benefit")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)

            ForEach(matrix.tiers, id: \.self) { tier in
                let style = MembershipTierStyle.style(for: tier)
                VStack(spacing: PRVSpacing.xxs) {
                    GradientMedallion(
                        systemName: style.symbolName,
                        gradient: style.gradient,
                        size: 30,
                        symbolColor: style.onGradient
                    )
                    Text(style.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: columnWidth)
                .accessibilityHidden(true)
            }
        }
    }

    private func benefitRow(_ row: TierComparisonMatrix.Row) -> some View {
        GridRow {
            HStack(spacing: PRVSpacing.xs) {
                Image(systemName: row.kind.membershipSymbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .frame(width: 18)
                Text(row.kind.membershipDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.prv.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: labelWidth, alignment: .leading)

            ForEach(matrix.tiers, id: \.self) { tier in
                cell(row.cell(for: tier), tier: tier)
                    .frame(width: columnWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
    }

    @ViewBuilder
    private func cell(_ cell: TierComparisonMatrix.Row.Cell, tier: MembershipTier) -> some View {
        let style = MembershipTierStyle.style(for: tier)
        switch cell {
        case .absent:
            Image(systemName: "minus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary.opacity(0.5))
                .frame(maxWidth: .infinity)
        case .included:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(style.accentTint)
                .frame(maxWidth: .infinity)
        case .value(let text):
            Text(text)
                .font(.footnote.weight(.bold))
                .foregroundStyle(style.accentTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Accessibility

    /// Reads a row as one sentence — "Member discount: Gold 15 percent,
    /// Diamond 20 percent, not in Silver" — because a VoiceOver user should
    /// never have to reconstruct a table from loose cells.
    private func accessibilityLabel(for row: TierComparisonMatrix.Row) -> String {
        var included: [String] = []
        var absent: [String] = []

        for tier in matrix.tiers {
            let title = MembershipTierStyle.style(for: tier).title
            switch row.cell(for: tier) {
            case .absent: absent.append(title)
            case .included: included.append(title)
            case .value(let text): included.append("\(title) \(text)")
            }
        }

        var sentence = row.kind.membershipDisplayName + ": "
        sentence += included.isEmpty ? "not included in any tier" : "included in " + included.joined(separator: ", ")
        if !absent.isEmpty, !included.isEmpty {
            sentence += ". Not in " + absent.joined(separator: ", ")
        }
        return sentence
    }
}

// MARK: - Previews

#Preview("Comparison Table — Light") {
    let plans = [
        PreviewData.goldPlan,
        MembershipPlan(
            salonID: PreviewData.salonLumiere.id,
            tier: .silver,
            name: "Lumière Silver",
            price: Money(49),
            cycle: .monthly,
            benefits: [
                MembershipBenefit(kind: .discountPercent, title: "10% off colour", value: 10),
                MembershipBenefit(kind: .priorityBooking, title: "Priority booking"),
            ]
        ),
        MembershipPlan(
            salonID: PreviewData.salonLumiere.id,
            tier: .diamond,
            name: "Lumière Diamond",
            price: Money(189),
            cycle: .monthly,
            benefits: [
                MembershipBenefit(kind: .freeService, title: "2 rituals a month", value: 2),
                MembershipBenefit(kind: .discountPercent, title: "25% off everything", value: 25),
                MembershipBenefit(kind: .priorityBooking, title: "Concierge booking"),
                MembershipBenefit(kind: .birthdayGift, title: "Birthday ritual"),
                MembershipBenefit(kind: .exclusiveEvents, title: "Atelier evenings"),
                MembershipBenefit(kind: .partnerBenefit, title: "Partner spa access"),
            ]
        ),
    ]

    ScrollView {
        TierComparisonTable(matrix: TierComparisonMatrix.build(from: plans))
            .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}

#Preview("Comparison Table — Dark") {
    ScrollView {
        TierComparisonTable(matrix: TierComparisonMatrix.build(from: [PreviewData.goldPlan]))
            .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
