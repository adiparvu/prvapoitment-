import SwiftUI
import PRVDesignSystem
import PRVModels

// MARK: - Benefit row

/// One membership benefit: a tier-tinted symbol, the salon's own wording, and
/// a figure badge when the benefit has a number worth shouting ("15%", "2×").
struct MembershipBenefitRow: View {
    /// The benefit to render.
    let benefit: MembershipBenefit
    /// Tint for the leading symbol, normally the tier's accent.
    var tint: Color = Color.prv.accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
            Image(systemName: benefit.kind.membershipSymbolName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(benefit.title)
                .font(.subheadline)
                .foregroundStyle(Color.prv.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: PRVSpacing.xxs)

            if let value = MembershipsFormatting.benefitValue(kind: benefit.kind, value: benefit.value) {
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.vertical, 2)
                    .padding(.horizontal, PRVSpacing.xs)
                    .background(tint.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let value = MembershipsFormatting.benefitValue(kind: benefit.kind, value: benefit.value) else {
            return benefit.title
        }
        return "\(benefit.title), \(value)"
    }
}

// MARK: - Plan card

/// A membership plan as a tier-styled glass card: gradient tier header, the
/// price in its billing cycle, and the first few benefits.
///
/// The whole card is one button — the detail sheet owns the commitment, so
/// nothing here can charge anybody by accident, and VoiceOver gets a single
/// clean element instead of a thicket of nested controls.
struct MembershipPlanCard: View {
    /// The plan on sale.
    let plan: MembershipPlan
    /// Salon behind the plan, shown when the grid spans several salons.
    var salonName: String?
    /// Whether to crown this plan "Most popular".
    var isFeatured = false
    /// Whether the client already holds this plan.
    var isSubscribed = false
    /// Opens the plan detail sheet.
    let action: () -> Void

    /// How many benefits fit on the card before it stops being scannable.
    private let benefitPreviewLimit = 3

    private var style: MembershipTierStyle { MembershipTierStyle.style(for: plan.tier) }

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            GradientHeaderCard(gradient: style.gradient) {
                header
            } content: {
                details
            }
        }
        .buttonStyle(PlanCardButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the full plan")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            // A translucent scrim rather than the tier gradient: the emblem
            // sits *on* that gradient and would otherwise disappear into it.
            GradientMedallion(
                systemName: style.symbolName,
                gradient: .membershipScrim,
                symbolColor: style.onGradient
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(style.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(style.onGradient)
                Text(salonName ?? style.tagline)
                    .font(.caption)
                    .foregroundStyle(style.onGradient.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: PRVSpacing.xxs)

            if isSubscribed {
                PRVBadge("Your plan", tint: Color.prv.success)
            } else if isFeatured {
                PRVBadge("Most popular", tint: Color.prv.gold)
            }
        }
    }

    // MARK: Body

    private var details: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            Text(plan.name)
                .prvStyle(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xxs) {
                PRVPriceLabel(plan.price.formatted, emphasis: .prominent)
                Text("/ \(MembershipsFormatting.cycleUnit(plan.cycle))")
                    .prvStyle(.subheadline)
            }

            if plan.cycle.months > 1 {
                Text("\(MembershipsFormatting.monthlyEquivalent(plan.price, cycle: plan.cycle).formatted) a month, billed \(plan.cycle.displayName.lowercased())")
                    .prvStyle(.caption)
            }

            if !previewBenefits.isEmpty {
                Divider().overlay(Color.prv.separator.opacity(0.5))

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    ForEach(previewBenefits) { benefit in
                        MembershipBenefitRow(benefit: benefit, tint: style.accentTint)
                    }
                    if hiddenBenefitCount > 0 {
                        Text("+\(hiddenBenefitCount) more benefit\(hiddenBenefitCount == 1 ? "" : "s")")
                            .prvStyle(.caption)
                            .padding(.leading, PRVSpacing.xl + PRVSpacing.xxs)
                    }
                }
            }

            HStack(spacing: PRVSpacing.xxs) {
                Text(isSubscribed ? "Manage plan" : "See what's included")
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(Color.prv.accent)
            .padding(.top, PRVSpacing.xxs)
        }
    }

    // MARK: Derived

    private var previewBenefits: [MembershipBenefit] {
        Array(plan.benefits.prefix(benefitPreviewLimit))
    }

    private var hiddenBenefitCount: Int {
        max(0, plan.benefits.count - benefitPreviewLimit)
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(style.title) tier",
            plan.name,
            MembershipsFormatting.pricePerCycle(plan.price, cycle: plan.cycle),
        ]
        if let salonName { parts.insert(salonName, at: 1) }
        if isSubscribed { parts.append("your current plan") }
        else if isFeatured { parts.append("most popular") }
        if !plan.benefits.isEmpty { parts.append("\(plan.benefits.count) benefits") }
        return parts.joined(separator: ", ")
    }
}

/// Press feedback for a whole-card button: a restrained scale, springing back
/// with the standard interactive motion.
private struct PlanCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .prvAnimation(PRVMotion.quick, value: configuration.isPressed)
    }
}

// MARK: - Active subscription card

/// A membership the client currently holds: status, renewal date, and the
/// cancel entry point.
struct ActiveSubscriptionCard: View {
    /// The subscription to render.
    let subscription: MembershipSubscription
    /// The plan behind it, when known.
    var plan: MembershipPlan?
    /// Salon behind the plan, when known.
    var salonName: String?
    /// `true` while a cancellation for this subscription is in flight.
    var isCancelling = false
    /// Asks to cancel — the caller confirms before anything happens.
    let onCancel: () -> Void

    private var tier: MembershipTier { plan?.tier ?? .custom }
    private var style: MembershipTierStyle { MembershipTierStyle.style(for: tier) }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                GradientMedallion(
                    systemName: style.symbolName,
                    gradient: style.gradient,
                    symbolColor: style.onGradient
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan?.name ?? "\(style.title) Membership")
                        .prvStyle(.headline)
                        .lineLimit(2)
                    if let salonName {
                        Text(salonName)
                            .prvStyle(.subheadline)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: PRVSpacing.xxs)

                PRVBadge(
                    subscription.status.membershipDisplayName,
                    tint: subscription.status.membershipTint
                )
            }

            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                DetailFactRow(
                    systemImage: subscription.status.membershipIsLive ? "arrow.triangle.2.circlepath" : "calendar.badge.exclamationmark",
                    title: renewalTitle,
                    tint: style.accentTint
                )

                if let plan {
                    DetailFactRow(
                        systemImage: "creditcard.fill",
                        title: "Billed \(plan.cycle.displayName.lowercased())",
                        value: plan.price.formatted,
                        tint: style.accentTint
                    )
                }

                DetailFactRow(
                    systemImage: "calendar",
                    title: "Member since \(subscription.startedAt.formatted(.dateTime.month(.abbreviated).year()))",
                    tint: style.accentTint
                )
            }

            if let benefits = plan?.benefits, !benefits.isEmpty {
                PRVFlowLayout(spacing: PRVSpacing.xs) {
                    ForEach(benefits) { benefit in
                        PRVTag(benefit.title, systemImage: benefit.kind.membershipSymbolName, tint: style.accentTint)
                    }
                }
            }

            if subscription.status.membershipIsLive {
                Button {
                    PRVHaptics.warning()
                    onCancel()
                } label: {
                    if isCancelling {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Cancel Membership")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.danger)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.prvGlass)
                .disabled(isCancelling)
                .accessibilityLabel("Cancel \(plan?.name ?? "this membership")")
                .accessibilityHint("You keep your benefits until the end of the paid period")
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .overlay {
            // A whisper of tier colour so a stack of memberships stays legible.
            PRVRadius.shape(PRVRadius.lg)
                .strokeBorder(style.accentTint.opacity(0.35), lineWidth: 1)
        }
    }

    private var renewalTitle: String {
        switch subscription.status {
        case .active, .pastDue:
            MembershipsFormatting.renewal(subscription.renewsAt)
        case .cancelled:
            MembershipsFormatting.benefitsUntil(subscription.renewsAt)
        case .expired:
            "Ended \(subscription.renewsAt.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }
}

// MARK: - Skeleton

/// The memberships screen's loading state: the same rhythm as the real
/// content, so nothing jumps when the data lands.
struct MembershipsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSkeleton(width: 160, height: 22)
                PRVSkeleton(height: 132, radius: PRVRadius.lg)
            }

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSkeleton(width: 120, height: 22)
                PRVSkeleton(height: 40, radius: PRVRadius.xl)
                PRVSkeleton(height: 220, radius: PRVRadius.xl)
                PRVSkeleton(height: 220, radius: PRVRadius.xl)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading memberships")
    }
}

// MARK: - Previews

#Preview("Plan Cards — Light") {
    ScrollView {
        VStack(spacing: PRVSpacing.lg) {
            MembershipPlanCard(
                plan: PreviewData.goldPlan,
                salonName: PreviewData.salonLumiere.name,
                isFeatured: true
            ) {}

            MembershipPlanCard(
                plan: MembershipPlan(
                    salonID: PreviewData.salonLumiere.id,
                    tier: .silver,
                    name: "Lumière Silver",
                    details: "A monthly blow-dry and 10% off colour.",
                    price: Money(49),
                    cycle: .monthly,
                    benefits: [
                        MembershipBenefit(kind: .discountPercent, title: "10% off colour services", value: 10),
                        MembershipBenefit(kind: .priorityBooking, title: "Priority booking"),
                    ]
                ),
                isSubscribed: true
            ) {}
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}

#Preview("Subscription Card — Dark") {
    ScrollView {
        ActiveSubscriptionCard(
            subscription: MembershipSubscription(
                planID: PreviewData.goldPlan.id,
                plan: PreviewData.goldPlan,
                userID: PreviewData.client.id,
                renewsAt: Date.now.addingTimeInterval(60 * 60 * 24 * 12)
            ),
            plan: PreviewData.goldPlan,
            salonName: PreviewData.salonLumiere.name
        ) {}
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Memberships Skeleton") {
    ScrollView {
        MembershipsSkeleton()
            .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}
