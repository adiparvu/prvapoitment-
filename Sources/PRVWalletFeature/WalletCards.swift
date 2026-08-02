import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Balance header

/// The wallet's hero: store credit and loyalty points on the brand gradient, with a
/// slow specular sheen travelling across the surface.
///
/// The sheen is the only decorative motion on the screen and is disabled entirely
/// under Reduce Motion; the card is an opaque gradient rather than glass, so Reduce
/// Transparency needs no separate fallback.
struct WalletBalanceCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let storeCredit: Money
    let points: Int
    let tier: LoyaltyTier
    let onPoints: () -> Void

    @State private var sheenPhase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text("Store credit")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.prv.textOnAccent.opacity(0.85))
                    Text(storeCredit.formatted)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.prv.textOnAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: PRVSpacing.xs)

                tierBadge
            }

            Button {
                PRVHaptics.tap()
                onPoints()
            } label: {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.footnote.weight(.bold))
                    Text("\(WalletFormatting.points(points)) points")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color.prv.textOnAccent)
                .padding(.vertical, PRVSpacing.xs)
                .padding(.horizontal, PRVSpacing.md)
                .background(.white.opacity(0.18), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(WalletFormatting.points(points)) loyalty points")
            .accessibilityHint("Opens your loyalty status")
        }
        .padding(PRVSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prv.accentGradient)
        .overlay { sheen }
        .clipShape(PRVRadius.shape(PRVRadius.xl))
        .overlay {
            PRVRadius.shape(PRVRadius.xl).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .prvSoftShadow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Beauty Wallet, \(storeCredit.formatted) store credit, \(tier.displayName) member")
    }

    private var tierBadge: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: LoyaltyTierStyle.style(for: tier).symbolName)
                .font(.caption.weight(.bold))
            Text(tier.displayName)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.prv.textOnAccent)
        .padding(.vertical, PRVSpacing.xxs)
        .padding(.horizontal, PRVSpacing.xs)
        .background(.white.opacity(0.2), in: Capsule())
        .accessibilityHidden(true)
    }

    /// A soft diagonal highlight that drifts across the card, once every few seconds.
    private var sheen: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: max(60, geometry.size.width * 0.35))
            .rotationEffect(.degrees(22))
            .offset(x: sheenPhase * geometry.size.width * 1.4)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 3.4).repeatForever(autoreverses: false).delay(0.6)) {
                sheenPhase = 1
            }
        }
    }
}

// MARK: - Ledger row

/// One movement in the wallet ledger: kind icon, title, date, and a signed amount
/// tinted success (money in) or danger (money out).
struct WalletTransactionRow: View {
    let transaction: WalletTransaction

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: transaction.kind.walletSymbolName)
                .font(.body)
                .foregroundStyle(WalletFormatting.signedTint(transaction.amount))
                .frame(width: 38, height: 38)
                .background(WalletFormatting.signedTint(transaction.amount).opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(2)
                Text("\(transaction.kind.walletDisplayName) · \(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .prvStyle(.caption)
                    .lineLimit(1)
            }

            Spacer(minLength: PRVSpacing.xs)

            VStack(alignment: .trailing, spacing: 2) {
                Text(WalletFormatting.signed(transaction.amount))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(WalletFormatting.signedTint(transaction.amount))
                    .monospacedDigit()
                if transaction.points != 0 {
                    Text("\(transaction.points > 0 ? "+" : "")\(WalletFormatting.points(transaction.points)) pts")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.prv.gold)
                }
            }
        }
        .padding(.vertical, PRVSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var summary = "\(transaction.title), \(transaction.kind.walletDisplayName), "
        summary += transaction.amount.amount < 0
            ? "\(transaction.amount.formatted) spent"
            : "\(transaction.amount.formatted) received"
        if transaction.points != 0 {
            summary += ", \(WalletFormatting.points(transaction.points)) points"
        }
        summary += ", \(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))"
        return summary
    }
}

// MARK: - Gift cards

/// A gift card in the wallet carousel: remaining balance, masked code, expiry.
struct GiftCardTile: View {
    let card: GiftCard

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            HStack {
                Image(systemName: "giftcard.fill")
                    .font(.title3)
                    .foregroundStyle(Color.prv.gold)
                    .accessibilityHidden(true)
                Spacer()
                if isDepleted {
                    PRVBadge("Used", tint: Color.prv.textSecondary)
                } else if let expiresAt {
                    PRVBadge(expiresAt.formatted(.dateTime.month(.abbreviated).year()), tint: Color.prv.gold)
                }
            }

            Text(card.remainingBalance.formatted)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Color.prv.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            VStack(alignment: .leading, spacing: 2) {
                Text(WalletFormatting.maskedCode(card.code))
                    .font(.footnote.weight(.medium))
                    .monospaced()
                    .foregroundStyle(Color.prv.textSecondary)
                Text("of \(card.initialBalance.formatted)")
                    .prvStyle(.caption)
            }
        }
        .frame(width: 170, alignment: .leading)
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .opacity(isDepleted ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Gift card, \(card.remainingBalance.formatted) remaining of \(card.initialBalance.formatted)"
        )
    }

    private var isDepleted: Bool { card.remainingBalance.isZero }
    private var expiresAt: Date? { card.expiresAt }
}

// MARK: - Invoices

/// An invoice row, with a share action when a PDF has been issued.
struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: "doc.text.fill")
                .font(.body)
                .foregroundStyle(Color.prv.accent)
                .frame(width: 38, height: 38)
                .background(Color.prv.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(invoice.number)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(invoice.issuedAt.formatted(date: .abbreviated, time: .omitted))
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            if let pdfURL = invoice.pdfURL {
                ShareLink(item: pdfURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share invoice \(invoice.number)")
            } else {
                Text("Preparing")
                    .prvStyle(.caption)
                    .accessibilityLabel("PDF is still being prepared")
            }
        }
        .padding(.vertical, PRVSpacing.xxs)
    }
}

// MARK: - Saved methods

/// A saved payment method summary row. No PAN data ever reaches the device — only
/// the tokenized label, last four digits, and expiry.
struct SavedMethodRow: View {
    let method: SavedPaymentMethod

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: method.kind.symbolName)
                .font(.body)
                .foregroundStyle(Color.prv.textPrimary)
                .frame(width: 38, height: 38)
                .background(Color.prv.surfaceElevated, in: PRVRadius.shape(PRVRadius.sm))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)
                if let expiry {
                    Text("Expires \(expiry)")
                        .prvStyle(.caption)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            if method.isDefault {
                PRVBadge("Default", tint: Color.prv.success)
            }
        }
        .padding(.vertical, PRVSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(method.isDefault ? "\(title), default method" : title)
    }

    private var title: String {
        guard let lastFour = method.lastFour else { return method.displayLabelOrKind }
        return "\(method.displayLabelOrKind) •••• \(lastFour)"
    }

    private var expiry: String? {
        guard let month = method.expiryMonth, let year = method.expiryYear else { return nil }
        return String(format: "%02d/%02d", month, year % 100)
    }
}

extension SavedPaymentMethod {
    /// The label to show, falling back to the method kind when the backend sends
    /// an empty display label.
    var displayLabelOrKind: String {
        displayLabel.isBlank ? kind.displayName : displayLabel
    }
}

// MARK: - Membership

/// Membership standing, or an invitation to join one. Tapping always lands on the
/// memberships screen via the shared router.
struct MembershipStatusCard: View {
    let subscription: MembershipSubscription?
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md) {
                HStack(spacing: PRVSpacing.md) {
                    Image(systemName: "crown.fill")
                        .font(.title3)
                        .foregroundStyle(Color.prv.gold)
                        .frame(width: 44, height: 44)
                        .background(Color.prv.gold.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        Text(title)
                            .prvStyle(.headline)
                            .lineLimit(1)
                        Text(subtitle)
                            .prvStyle(.footnote)
                            .lineLimit(2)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    if let subscription {
                        PRVBadge(statusTitle(subscription.status), tint: statusTint(subscription.status))
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
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityHint("Opens memberships")
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        subscription?.plan?.name ?? (subscription == nil ? "No membership yet" : "Membership")
    }

    private var subtitle: String {
        guard let subscription else {
            return "Join a plan for monthly rituals, priority booking, and member pricing."
        }
        switch subscription.status {
        case .active:
            return "Renews \(subscription.renewsAt.formatted(date: .abbreviated, time: .omitted))"
        case .pastDue:
            return "Payment failed — update your method to keep your benefits."
        case .cancelled:
            return "Cancelled. Your benefits run until \(subscription.renewsAt.formatted(date: .abbreviated, time: .omitted))."
        case .expired:
            return "Expired. Rejoin any time to get your benefits back."
        }
    }

    private func statusTitle(_ status: MembershipSubscription.Status) -> String {
        switch status {
        case .active: "Active"
        case .pastDue: "Past due"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }

    private func statusTint(_ status: MembershipSubscription.Status) -> Color {
        switch status {
        case .active: Color.prv.success
        case .pastDue: Color.prv.warning
        case .cancelled, .expired: Color.prv.textSecondary
        }
    }
}

// MARK: - Skeleton

/// The wallet's loading state: a gradient-free balance block plus a few ledger rows,
/// all shimmering. Hidden from assistive technology.
struct WalletSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            PRVSkeleton(height: 150, radius: PRVRadius.xl)

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSkeleton(width: 140, height: 20)
                ForEach(0 ..< 4, id: \.self) { _ in
                    HStack(spacing: PRVSpacing.sm) {
                        PRVSkeleton(width: 38, height: 38, radius: 19)
                        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                            PRVSkeleton(width: 170, height: 14)
                            PRVSkeleton(width: 110, height: 11)
                        }
                        Spacer()
                        PRVSkeleton(width: 62, height: 14)
                    }
                }
            }

            PRVSkeleton(height: 96, radius: PRVRadius.lg)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Wallet — Cards") {
    ScrollView {
        VStack(spacing: PRVSpacing.lg) {
            WalletBalanceCard(storeCredit: Money(128), points: 1_240, tier: .gold) {}

            VStack(spacing: PRVSpacing.xs) {
                WalletTransactionRow(
                    transaction: WalletTransaction(
                        userID: PreviewData.client.id,
                        kind: .payment,
                        amount: Money(-185),
                        points: 235,
                        title: "Balayage & Gloss"
                    )
                )
                WalletTransactionRow(
                    transaction: WalletTransaction(
                        userID: PreviewData.client.id,
                        kind: .cashback,
                        amount: Money(4),
                        title: "Prepayment cashback"
                    )
                )
            }
            .prvGlassCard()

            MembershipStatusCard(
                subscription: MembershipSubscription(
                    planID: PreviewData.goldPlan.id,
                    plan: PreviewData.goldPlan,
                    userID: PreviewData.client.id,
                    renewsAt: Date.now.addingTimeInterval(60 * 60 * 24 * 21)
                )
            ) {}

            MembershipStatusCard(subscription: nil) {}
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}

#Preview("Wallet — Skeleton") {
    WalletSkeleton()
        .padding(PRVSpacing.lg)
        .background(Color.prv.canvas)
}
