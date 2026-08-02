import SwiftUI
import PRVFoundation
import PRVModels
import PRVDesignSystem

// MARK: - Upcoming appointment hero

/// The hero card at the top of the home screen: the client's next
/// appointment with a live countdown, plus directions and reschedule
/// actions. Tapping the card body opens the appointment detail.
struct UpcomingAppointmentCard: View {
    let hero: HomeModel.UpcomingHero
    let onOpen: () -> Void
    let onDirections: () -> Void
    let onReschedule: () -> Void

    private var appointment: Appointment { hero.appointment }

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                Button {
                    PRVHaptics.tap()
                    onOpen()
                } label: {
                    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                        HStack(alignment: .center) {
                            PRVBadge(appointment.status.displayName, tint: statusTint)
                            Spacer(minLength: PRVSpacing.xs)
                            if let start = appointment.start {
                                countdownPill(until: start)
                            }
                        }

                        Text(serviceNames)
                            .prvStyle(.title2)
                            .multilineTextAlignment(.leading)

                        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                            detailRow(systemImage: "person.fill", text: professionalLine)
                            if let start = appointment.start {
                                detailRow(
                                    systemImage: "calendar",
                                    text: start.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint("Opens appointment details")

                HStack(spacing: PRVSpacing.sm) {
                    Button {
                        PRVHaptics.tap()
                        onDirections()
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.prvGlass)
                    .accessibilityLabel("Directions to \(appointment.salonName)")

                    Button {
                        PRVHaptics.tap()
                        onReschedule()
                    } label: {
                        Label("Reschedule", systemImage: "calendar.badge.clock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.prvGlass)
                    .accessibilityLabel("Reschedule appointment")
                }
            }
        }
    }

    /// Gradient capsule showing time remaining, refreshed every minute.
    private func countdownPill(until start: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.countdownText(until: start, now: context.date))
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.prv.textOnAccent)
                .padding(.vertical, PRVSpacing.xxs)
                .padding(.horizontal, PRVSpacing.sm)
                .background(Color.prv.accentGradient, in: Capsule())
                .accessibilityLabel("Starts \(Self.countdownText(until: start, now: context.date).lowercased())")
        }
    }

    private func detailRow(systemImage: String, text: String) -> some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(Color.prv.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .prvStyle(.subheadline)
                .lineLimit(1)
        }
    }

    private var serviceNames: String {
        appointment.items.map(\.serviceName).joined(separator: " + ")
    }

    private var professionalLine: String {
        let professionals = appointment.items.compactMap(\.professionalName)
        if professionals.isEmpty { return appointment.salonName }
        return "\(professionals.joined(separator: ", ")) · \(appointment.salonName)"
    }

    private var statusTint: Color {
        switch appointment.status {
        case .confirmed, .checkedIn, .inProgress: Color.prv.success
        case .pendingConfirmation: Color.prv.warning
        default: Color.prv.accent
        }
    }

    private var accessibilitySummary: String {
        var summary = "\(serviceNames) at \(appointment.salonName)"
        if let start = appointment.start {
            summary += ", \(start.formatted(date: .abbreviated, time: .shortened))"
        }
        return summary
    }

    /// "In 3d 4h", "In 2h 15m", "In 12m", or "Starting now".
    nonisolated static func countdownText(until start: Date, now: Date) -> String {
        let totalMinutes = Int(start.timeIntervalSince(now) / 60)
        guard totalMinutes > 0 else { return "Starting now" }
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "In \(days)d \(hours)h" }
        if hours > 0 { return "In \(hours)h \(minutes)m" }
        return "In \(minutes)m"
    }
}

// MARK: - Salon rail card

/// Compact salon card used inside the horizontal home rails.
struct HomeSalonCard: View {
    let salon: Salon
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard(radius: PRVRadius.lg, padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    PRVAsyncImage(url: salon.heroImageURL)
                        .frame(height: 132)
                        .clipped()
                        .overlay(alignment: .topLeading) {
                            if salon.isVerified {
                                PRVBadge("Verified", tint: Color.prv.success)
                                    .padding(PRVSpacing.xs)
                            }
                        }

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        Text(salon.name)
                            .prvStyle(.headline)
                            .lineLimit(1)

                        HStack(spacing: PRVSpacing.xxs) {
                            PRVRatingStars(rating: salon.rating)
                            Text(ratingText)
                                .prvStyle(.caption)
                        }

                        HStack(spacing: PRVSpacing.xxs) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(Color.prv.textSecondary)
                                .accessibilityHidden(true)
                            Text(salon.address.city)
                                .prvStyle(.caption)
                                .lineLimit(1)
                        }

                        if let category = salon.categories.first {
                            PRVTag(category.displayName, systemImage: category.symbolName)
                                .padding(.top, PRVSpacing.xxs)
                        }
                    }
                    .padding(PRVSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 250)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(salon.name), rated \(salon.rating.formatted(.number.precision(.fractionLength(1)))) out of 5, in \(salon.address.city)"
        )
        .accessibilityAddTraits(.isButton)
    }

    private var ratingText: String {
        "\(salon.rating.formatted(.number.precision(.fractionLength(1)))) (\(salon.reviewCount))"
    }
}

// MARK: - Loyalty banner

/// Glass banner summarizing loyalty status: tier emblem inside a progress
/// ring, XP to the next tier, and spendable points. Tapping opens loyalty.
struct LoyaltyBanner: View {
    let profile: LoyaltyProfile
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
                HStack(spacing: PRVSpacing.md) {
                    PRVProgressRing(
                        progress: profile.progressToNextTier,
                        lineWidth: 6,
                        size: 64,
                        tint: Color.prv.gold
                    ) {
                        Image(systemName: "crown.fill")
                            .font(.title3)
                            .foregroundStyle(Color.prv.gold)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        Text("\(profile.tier.displayName) Member")
                            .prvStyle(.headline)
                        Text(progressCaption)
                            .prvStyle(.footnote)
                        Text("\(profile.spendablePoints.formatted()) points to spend")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.prv.gold)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.tier.displayName) member, \(progressCaption), \(profile.spendablePoints.formatted()) points to spend")
        .accessibilityAddTraits(.isButton)
    }

    private var progressCaption: String {
        if let next = profile.tier.next {
            return "\((next.threshold - profile.xp).formatted()) XP to \(next.displayName)"
        }
        return "Top tier — enjoy everything"
    }
}

// MARK: - Package card

/// Card for an active offer/package inside the offers rail.
struct PackageCard: View {
    let package: ServicePackage
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard(radius: PRVRadius.lg, padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    PRVAsyncImage(url: package.imageURL)
                        .frame(height: 110)
                        .clipped()
                        .overlay(alignment: .topLeading) {
                            PRVBadge("Save \(package.savings.formatted)", tint: Color.prv.success)
                                .padding(PRVSpacing.xs)
                        }

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        PRVTag(package.theme.homeDisplayName, systemImage: package.theme.homeSymbolName, tint: Color.prv.accent)
                        Text(package.name)
                            .prvStyle(.headline)
                            .lineLimit(1)
                        Text(package.details)
                            .prvStyle(.caption)
                            .lineLimit(2)
                        PRVPriceLabel(
                            package.packagePrice.formatted,
                            originalPrice: package.regularPrice.formatted
                        )
                        .padding(.top, PRVSpacing.xxs)
                    }
                    .padding(PRVSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 270)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(package.name), \(package.packagePrice.formatted), was \(package.regularPrice.formatted)"
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// Home-local display metadata for package themes.
extension ServicePackage.Theme {
    var homeDisplayName: String {
        switch self {
        case .wedding: "Wedding"
        case .holiday: "Holiday"
        case .seasonal: "Seasonal"
        case .monthly: "Monthly"
        case .luxurySpa: "Luxury Spa"
        case .combo: "Combo"
        case .custom: "Special"
        }
    }

    var homeSymbolName: String {
        switch self {
        case .wedding: "heart.fill"
        case .holiday: "gift.fill"
        case .seasonal: "leaf.fill"
        case .monthly: "calendar"
        case .luxurySpa: "sparkles"
        case .combo: "square.stack.3d.up.fill"
        case .custom: "star.fill"
        }
    }
}

// MARK: - Wallet snapshot tile

/// One-glance Beauty Wallet tile: store credit and reward points.
struct WalletSnapshotTile: View {
    let snapshot: HomeModel.WalletSnapshot
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard {
                HStack(spacing: PRVSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.prv.accentGradient)
                            .frame(width: 44, height: 44)
                        Image(systemName: "wallet.pass.fill")
                            .font(.body)
                            .foregroundStyle(Color.prv.textOnAccent)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Beauty Wallet")
                            .prvStyle(.headline)
                        Text("Store credit, cashback & rewards")
                            .prvStyle(.caption)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(snapshot.storeCredit.formatted)
                            .font(.system(.body, design: .rounded, weight: .bold))
                            .foregroundStyle(Color.prv.textPrimary)
                        Text("\(snapshot.points.formatted()) pts")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.prv.gold)
                    }

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Beauty Wallet, \(snapshot.storeCredit.formatted) store credit, \(snapshot.points.formatted()) points"
        )
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - AI assistant entry

/// Entry card for the AI Beauty Assistant.
struct AssistantEntryCard: View {
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.impact()
            action()
        } label: {
            PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
                HStack(spacing: PRVSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.prv.accentGradient)
                            .frame(width: 48, height: 48)
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(Color.prv.textOnAccent)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        Text("Ask your Beauty Assistant")
                            .prvStyle(.headline)
                        Text("Describe the look you want — get services, pros, and timing planned for you.")
                            .prvStyle(.footnote)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ask your Beauty Assistant")
        .accessibilityHint("Opens the AI assistant")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Section error & skeletons

/// Inline, quiet error surface for a single failed home section.
struct HomeSectionErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        PRVGlassCard {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(Color.prv.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .prvStyle(.footnote)
                Spacer(minLength: PRVSpacing.xs)
                Button {
                    PRVHaptics.tap()
                    retry()
                } label: {
                    Text("Retry")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                }
                .accessibilityLabel("Retry loading")
            }
        }
    }
}

/// Skeleton for the appointment hero while it loads.
struct HeroSkeleton: View {
    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack {
                    PRVSkeleton(width: 84, height: 20, radius: 10)
                    Spacer()
                    PRVSkeleton(width: 72, height: 20, radius: 10)
                }
                PRVSkeleton(width: 210, height: 22)
                PRVSkeleton(width: 160, height: 14)
                PRVSkeleton(width: 130, height: 14)
                HStack(spacing: PRVSpacing.sm) {
                    PRVSkeleton(height: 40, radius: PRVRadius.md)
                    PRVSkeleton(height: 40, radius: PRVRadius.md)
                }
                .padding(.top, PRVSpacing.xs)
            }
        }
    }
}

/// Skeleton for a horizontal rail of cards while it loads.
struct RailSkeleton: View {
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PRVSpacing.md) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        PRVSkeleton(height: 132, radius: PRVRadius.lg)
                        PRVSkeleton(width: 150, height: 16)
                        PRVSkeleton(width: 100, height: 12)
                    }
                    .frame(width: 250)
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Upcoming Appointment Card") {
    UpcomingAppointmentCard(
        hero: HomeModel.UpcomingHero(
            appointment: PreviewData.upcomingAppointment,
            salon: PreviewData.salonLumiere
        ),
        onOpen: {},
        onDirections: {},
        onReschedule: {}
    )
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Loyalty Banner & Wallet") {
    VStack(spacing: PRVSpacing.md) {
        LoyaltyBanner(profile: PreviewData.loyaltyProfile) {}
        WalletSnapshotTile(
            snapshot: HomeModel.WalletSnapshot(storeCredit: Money(35), points: 1_240)
        ) {}
        AssistantEntryCard {}
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Salon & Package Cards") {
    ScrollView(.horizontal) {
        HStack(spacing: PRVSpacing.md) {
            HomeSalonCard(salon: PreviewData.salonLumiere) {}
            PackageCard(package: PreviewData.weddingPackage) {}
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}
