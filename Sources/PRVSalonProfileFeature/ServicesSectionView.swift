import SwiftUI
import PRVModels
import PRVDesignSystem

/// The Services section: the salon's menu grouped by category. Each row
/// shows price and duration, toggles in and out of the pending booking, and
/// discloses selectable add-ons where the service offers them.
struct ServicesSectionView: View {
    let model: SalonProfileModel

    var body: some View {
        if model.services.isEmpty {
            PRVEmptyState(
                systemImage: "scissors",
                title: "No services listed yet",
                message: "This salon hasn't published its menu. Check back soon."
            )
        } else {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                ForEach(model.groupedServices) { group in
                    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                        HStack(spacing: PRVSpacing.xs) {
                            Image(systemName: group.category.symbolName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.prv.accent)
                                .accessibilityHidden(true)
                            Text(group.category.displayName)
                                .prvStyle(.title2)
                                .accessibilityAddTraits(.isHeader)
                        }

                        ForEach(group.services) { service in
                            ServiceRow(service: service, model: model)
                        }
                    }
                }
            }
        }
    }
}

/// One service in the menu: name, description, duration, price, the
/// add-to-booking toggle, and an add-ons disclosure when available.
struct ServiceRow: View {
    let service: SalonService
    let model: SalonProfileModel

    @State private var showsAddOns = false

    private var isSelected: Bool { model.isSelected(service) }

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                Button {
                    model.toggleService(service)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(isSelected ? "Removes it from your booking" : "Adds it to your booking")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])

                if !service.addOns.isEmpty {
                    Divider()

                    DisclosureGroup(isExpanded: $showsAddOns) {
                        VStack(spacing: PRVSpacing.xs) {
                            ForEach(service.addOns) { addOn in
                                AddOnRow(addOn: addOn, service: service, model: model)
                            }
                        }
                        .padding(.top, PRVSpacing.xs)
                    } label: {
                        Text(addOnsTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.accent)
                    }
                    .tint(Color.prv.accent)
                    .prvAnimation(PRVMotion.spring, value: showsAddOns)
                }
            }
        }
        .prvAnimation(PRVMotion.quick, value: isSelected)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                HStack(spacing: PRVSpacing.xs) {
                    Text(service.name)
                        .prvStyle(.headline)
                        .multilineTextAlignment(.leading)
                    if service.requiresPrepayment {
                        PRVBadge("Deposit", tint: Color.prv.warning)
                    }
                }

                if !service.details.isEmpty {
                    Text(service.details)
                        .prvStyle(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(Color.prv.textSecondary)
                    Text(ProfileFormatting.duration(service.durationMinutes))
                        .prvStyle(.footnote)

                    Spacer(minLength: PRVSpacing.xs)

                    PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
                }
                .padding(.top, PRVSpacing.xxs)
            }

            selectionIndicator
        }
        .contentShape(Rectangle())
    }

    /// The add / added toggle affordance.
    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
            .font(.title2)
            .foregroundStyle(isSelected ? Color.prv.success : Color.prv.accent)
            .symbolEffect(.bounce, value: isSelected)
            .accessibilityHidden(true)
    }

    private var addOnsTitle: String {
        let count = service.addOns.count
        return count == 1 ? "1 add-on available" : "\(count) add-ons available"
    }

    private var accessibilityLabel: String {
        var label = "\(service.name), "
        label += service.isStartingPrice ? "from \(service.price.formatted)" : service.price.formatted
        label += ", \(ProfileFormatting.duration(service.durationMinutes))"
        if isSelected { label += ", added to booking" }
        return label
    }
}

/// One selectable add-on beneath its parent service.
struct AddOnRow: View {
    let addOn: ServiceAddOn
    let service: SalonService
    let model: SalonProfileModel

    private var isSelected: Bool { model.isSelected(addOn, of: service) }

    var body: some View {
        Button {
            model.toggleAddOn(addOn, of: service)
        } label: {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.prv.success : Color.prv.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(addOn.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .multilineTextAlignment(.leading)
                    if addOn.extraMinutes > 0 {
                        Text("+\(ProfileFormatting.duration(addOn.extraMinutes))")
                            .prvStyle(.caption)
                    }
                }

                Spacer(minLength: PRVSpacing.xs)

                Text("+\(addOn.price.formatted)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .prvAnimation(PRVMotion.quick, value: isSelected)
        .accessibilityLabel("\(addOn.name), \(addOn.price.formatted) extra")
        .accessibilityHint(isSelected ? "Removes the add-on" : "Adds the add-on")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Loads the in-memory backend before showing the section on its own.
private struct ServicesSectionPreview: View {
    @Environment(\.prvDependencies) private var deps
    @State private var model = SalonProfileModel(salonID: PreviewData.salonLumiere.id)

    var body: some View {
        ScrollView {
            ServicesSectionView(model: model)
                .padding(PRVSpacing.md)
        }
        .background(Color.prv.canvas)
        .task { await model.load(using: deps) }
    }
}

#Preview("Services Section") {
    ServicesSectionPreview()
        .environment(UserSession.previewClient)
        .environment(AppRouter())
}
