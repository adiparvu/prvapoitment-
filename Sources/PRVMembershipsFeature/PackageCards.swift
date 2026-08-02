import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// A service package as a themed card: a symbol header on a theme gradient,
/// the bundle price against the regular price, what it saves, how long the
/// buyer has to redeem it, and — on request — exactly what is inside.
///
/// The included-services list is collapsed by default and resolved lazily,
/// because the names come from a different repository than the package
/// itself. Expanding is the client asking "what am I actually buying"; the
/// answer arrives with a skeleton, never with a frozen card.
struct PackageCard: View {
    /// The package on sale.
    let package: ServicePackage
    /// Salon behind it, shown when the list spans several salons.
    var salonName: String?
    /// Resolution state of the included services.
    let resolution: PackagesModel.ServiceResolution
    /// Whether the included-services list is showing.
    let isExpanded: Bool
    /// `true` while this package's purchase is in flight.
    var isPurchasing = false
    /// `false` for guests — browsing stays open, buying does not.
    var canPurchase = true
    /// Toggles the included-services list.
    let onToggleExpand: () -> Void
    /// Retries a failed service resolution.
    let onRetryServices: () -> Void
    /// Starts the purchase.
    let onPurchase: () -> Void

    private var style: PackageThemeStyle { PackageThemeStyle.style(for: package.theme) }

    var body: some View {
        GradientHeaderCard(gradient: style.gradient) {
            header
        } content: {
            details
        }
        .prvAnimation(PRVMotion.spring, value: isExpanded)
        .prvAnimation(PRVMotion.quick, value: resolution)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            GradientMedallion(
                systemName: style.symbolName,
                gradient: .membershipScrim,
                symbolColor: Color.prv.textOnAccent
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(style.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.prv.textOnAccent)
                Text(salonName ?? style.tagline)
                    .font(.caption)
                    .foregroundStyle(Color.prv.textOnAccent.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: PRVSpacing.xxs)

            if package.savings.amount > 0 {
                SavingsBadge(
                    savings: package.savings,
                    percent: MembershipsFormatting.savingsPercent(package)
                )
            }
        }
    }

    // MARK: Body

    private var details: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            Text(package.name)
                .prvStyle(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if !package.details.isBlank {
                Text(package.details)
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PRVPriceLabel(
                package.packagePrice.formatted,
                originalPrice: package.savings.amount > 0 ? package.regularPrice.formatted : nil,
                emphasis: .prominent
            )

            DetailFactRow(
                systemImage: "clock.badge.checkmark",
                title: MembershipsFormatting.validity(package.validityDays),
                tint: style.accentTint
            )

            includedServices

            Button {
                PRVHaptics.impact()
                onPurchase()
            } label: {
                if isPurchasing {
                    ProgressView()
                        .tint(Color.prv.textOnAccent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(purchaseTitle)
                }
            }
            .buttonStyle(.prvPrimary)
            .disabled(!canPurchase || isPurchasing)
            .accessibilityLabel(purchaseAccessibilityLabel)
            .padding(.top, PRVSpacing.xxs)
        }
    }

    // MARK: Included services

    @ViewBuilder
    private var includedServices: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Button {
                PRVHaptics.tap()
                onToggleExpand()
            } label: {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "list.bullet")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(style.accentTint)
                        .frame(width: 22)
                    Text(serviceCountTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                    Spacer(minLength: PRVSpacing.xxs)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.prv.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(serviceCountTitle)
            .accessibilityHint(isExpanded ? "Hides the included services" : "Shows the included services")
            .accessibilityAddTraits(isExpanded ? [.isSelected] : [])

            if isExpanded {
                resolvedServices
                    .transition(.opacity.combined(with: .offset(y: -PRVSpacing.xs)))
            }
        }
    }

    @ViewBuilder
    private var resolvedServices: some View {
        switch resolution {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                ForEach(0 ..< max(1, package.serviceIDs.count), id: \.self) { _ in
                    PRVSkeleton(height: 38, radius: PRVRadius.sm)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading the included services")

        case .loaded(let services):
            if services.isEmpty {
                Text("The salon will confirm the exact treatments when you book.")
                    .prvStyle(.caption)
            } else {
                VStack(spacing: PRVSpacing.xs) {
                    ForEach(services) { service in
                        IncludedServiceRow(service: service, tint: style.accentTint)
                        if service.id != services.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .padding(PRVSpacing.sm)
                .background(Color.prv.surface.opacity(0.6), in: PRVRadius.shape(PRVRadius.md))
            }

        case .failed(let message):
            InlineFailureCard(message: message) { onRetryServices() }
        }
    }

    // MARK: Derived

    private var serviceCountTitle: String {
        let count = package.serviceIDs.count
        switch count {
        case 0: return "What's included"
        case 1: return "1 service included"
        default: return "\(count) services included"
        }
    }

    private var purchaseTitle: String {
        canPurchase ? "Buy for \(package.packagePrice.formatted)" : "Sign in to buy"
    }

    private var purchaseAccessibilityLabel: String {
        guard canPurchase else { return "Sign in to buy this package" }
        return "Buy \(package.name) for \(package.packagePrice.formatted)"
    }
}

// MARK: - Included service row

/// One treatment inside a package: category symbol, name, duration, and the
/// price it would carry on its own.
struct IncludedServiceRow: View {
    /// The resolved service.
    let service: SalonService
    /// Icon tint, normally the package theme's accent.
    var tint: Color = Color.prv.accent

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: service.category.symbolName)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(2)
                Text(MembershipsFormatting.duration(minutes: service.durationMinutes))
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            Text(service.price.formatted)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary)
                .strikethrough()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(service.name), \(MembershipsFormatting.duration(minutes: service.durationMinutes)), normally \(service.price.formatted)"
        )
    }
}

// MARK: - Skeleton

/// The packages screen's loading state.
struct PackagesSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            PRVSkeleton(width: 180, height: 22)
            PRVSkeleton(height: 260, radius: PRVRadius.xl)
            PRVSkeleton(height: 260, radius: PRVRadius.xl)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading packages")
    }
}

// MARK: - Previews

#Preview("Package Card — Light") {
    ScrollView {
        VStack(spacing: PRVSpacing.lg) {
            PackageCard(
                package: PreviewData.weddingPackage,
                salonName: PreviewData.salonLumiere.name,
                resolution: .loaded([PreviewData.serviceBalayage, PreviewData.serviceCutBlowDry]),
                isExpanded: true,
                onToggleExpand: {},
                onRetryServices: {},
                onPurchase: {}
            )

            PackageCard(
                package: ServicePackage(
                    salonID: PreviewData.salonVelvet.id,
                    name: "Winter Glow Ritual",
                    details: "A gel manicure and a hydrating facial, every month through winter.",
                    theme: .seasonal,
                    serviceIDs: [PreviewData.serviceGelManicure.id],
                    regularPrice: Money(165),
                    packagePrice: Money(139),
                    validityDays: 90
                ),
                resolution: .loading,
                isExpanded: true,
                onToggleExpand: {},
                onRetryServices: {},
                onPurchase: {}
            )
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}

#Preview("Package Card — Dark") {
    ScrollView {
        PackageCard(
            package: PreviewData.weddingPackage,
            resolution: .failed("You appear to be offline."),
            isExpanded: true,
            canPurchase: false,
            onToggleExpand: {},
            onRetryServices: {},
            onPurchase: {}
        )
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
