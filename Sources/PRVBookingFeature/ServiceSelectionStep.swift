import SwiftUI
import PRVDesignSystem
import PRVModels

/// Step 1 — the salon's menu grouped by category. Services toggle in and out
/// of the booking and disclose their add-ons inline, while the running total
/// lives in the flow's floating bottom bar.
struct ServiceSelectionStepView: View {
    let model: BookingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            if model.services.isEmpty {
                PRVEmptyState(
                    systemImage: "scissors",
                    title: "No services published",
                    message: "This salon hasn't published its menu yet. Message them to arrange your visit."
                )
            } else {
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
                            BookingServiceRow(service: service, model: model)
                        }
                    }
                }
            }
        }
    }
}

/// One service in the booking menu: name, description, duration, price, the
/// add/remove control, and a disclosure for its add-ons.
struct BookingServiceRow: View {
    let service: SalonService
    let model: BookingFlowModel

    @State private var showsAddOns = false

    private var isSelected: Bool { model.isSelected(service) }

    private var selectedAddOnCount: Int { model.selectedAddOns(of: service).count }

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
                .accessibilityIdentifier("booking.serviceRow")

                if !service.addOns.isEmpty {
                    Divider()

                    DisclosureGroup(isExpanded: $showsAddOns) {
                        VStack(spacing: PRVSpacing.xs) {
                            ForEach(service.addOns) { addOn in
                                BookingAddOnRow(addOn: addOn, service: service, model: model)
                            }
                        }
                        .padding(.top, PRVSpacing.xs)
                    } label: {
                        HStack(spacing: PRVSpacing.xs) {
                            Text(addOnsTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.prv.accent)
                            if selectedAddOnCount > 0 {
                                PRVBadge(count: selectedAddOnCount, tint: Color.prv.accent)
                            }
                        }
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
                        .accessibilityHidden(true)
                    Text(BookingFormatting.duration(service.durationMinutes))
                        .prvStyle(.footnote)

                    Spacer(minLength: PRVSpacing.xs)

                    PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
                }
                .padding(.top, PRVSpacing.xxs)
            }

            Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.prv.success : Color.prv.accent)
                .symbolEffect(.bounce, value: isSelected)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var addOnsTitle: String {
        service.addOns.count == 1 ? "1 add-on available" : "\(service.addOns.count) add-ons available"
    }

    private var accessibilityLabel: String {
        var label = "\(service.name), "
        label += service.isStartingPrice ? "from \(service.price.formatted)" : service.price.formatted
        label += ", \(BookingFormatting.duration(service.durationMinutes))"
        if service.requiresPrepayment { label += ", deposit required" }
        if isSelected { label += ", added to your booking" }
        return label
    }
}

/// One selectable add-on beneath its parent service.
struct BookingAddOnRow: View {
    let addOn: ServiceAddOn
    let service: SalonService
    let model: BookingFlowModel

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
                        Text("+\(BookingFormatting.duration(addOn.extraMinutes))")
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
