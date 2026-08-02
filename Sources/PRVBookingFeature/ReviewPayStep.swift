import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Step 4 — the whole visit in one glance, then how it gets paid: the summary
/// with the salon's cancellation policy, a note for the artist, the salon's
/// prepayment levels with every benefit computed, and a coupon field.
struct ReviewPayStepView: View {
    let model: BookingFlowModel
    /// Jumps back to an earlier step from an "Edit" affordance.
    let onEdit: (BookingStep) -> Void
    /// Validates the typed coupon code.
    let applyCoupon: () -> Void

    @FocusState private var isCouponFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            summaryCard
            notesCard
            prepaymentSection
            couponCard
            totalsCard
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.salon?.name ?? "Your salon")
                            .prvStyle(.title2)
                        if let address = model.salon?.address.oneLine {
                            Text(address)
                                .prvStyle(.footnote)
                        }
                    }
                    Spacer(minLength: PRVSpacing.xs)
                    if model.salon?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(Color.prv.accent)
                            .accessibilityLabel("Verified salon")
                    }
                }

                Divider()

                servicesSummary

                Divider()

                VStack(spacing: PRVSpacing.xs) {
                    editableRow(
                        label: "Artist",
                        value: model.selectedProfessional?.displayName ?? "Any available",
                        systemImage: "person.crop.circle",
                        step: .professional
                    )
                    editableRow(
                        label: "When",
                        value: model.selectedSlot.map { BookingFormatting.dateAndTime($0.start) } ?? "Not chosen",
                        systemImage: "calendar",
                        step: .time
                    )
                    BookingSummaryRow(
                        label: "Duration",
                        value: BookingFormatting.duration(model.totalDurationMinutes),
                        systemImage: "clock"
                    )
                    if let rule = model.recurrenceRule {
                        BookingSummaryRow(
                            label: "Repeats",
                            value: BookingFormatting.recurrence(rule),
                            systemImage: "repeat"
                        )
                    }
                    if model.isGroupBooking {
                        BookingSummaryRow(
                            label: "Group",
                            value: model.guestCount == 1 ? "You + 1 guest" : "You + \(model.guestCount) guests",
                            systemImage: "person.2.fill"
                        )
                    }
                }

                if let policies = model.salon?.policies {
                    cancellationNote(policies)
                }
            }
        }
    }

    private var servicesSummary: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack {
                Text("Treatments")
                    .prvStyle(.headline)
                Spacer(minLength: PRVSpacing.xs)
                Button("Edit") {
                    onEdit(.services)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .accessibilityLabel("Edit treatments")
            }

            ForEach(model.selectedServices) { service in
                BookingSummaryRow(label: service.name, value: service.price.formatted)
                ForEach(model.selectedAddOns(of: service)) { addOn in
                    HStack(spacing: PRVSpacing.xs) {
                        Image(systemName: "plus")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary)
                            .accessibilityHidden(true)
                        Text(addOn.name)
                            .prvStyle(.footnote)
                        Spacer(minLength: PRVSpacing.xs)
                        Text(addOn.price.formatted)
                            .prvStyle(.footnote)
                    }
                    .padding(.leading, PRVSpacing.sm)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func editableRow(
        label: String,
        value: String,
        systemImage: String,
        step: BookingStep
    ) -> some View {
        Button {
            onEdit(step)
        } label: {
            HStack(spacing: PRVSpacing.sm) {
                BookingSummaryRow(label: label, value: value, systemImage: systemImage)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint("Double tap to change")
    }

    private func cancellationNote(_ policies: SalonPolicies) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.footnote)
                .foregroundStyle(Color.prv.success)
                .accessibilityHidden(true)
            Text(BookingFormatting.cancellationPolicy(policies))
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.success.opacity(0.10), in: PRVRadius.shape(PRVRadius.sm))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Notes

    private var notesCard: some View {
        @Bindable var model = model

        return PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text("Note for your artist")
                    .prvStyle(.headline)
                Text("Allergies, inspiration, parking — anything that helps.")
                    .prvStyle(.caption)

                TextField("Optional", text: $model.notes, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.sentences)
                    .padding(PRVSpacing.sm)
                    .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                    .accessibilityLabel("Note for your artist")
            }
        }
    }

    // MARK: - Prepayment

    private var prepaymentSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(
                "How you'd like to pay",
                subtitle: model.requiresPrepayment
                    ? "One of your treatments requires a deposit"
                    : "Prepaying unlocks extra rewards"
            )

            ForEach(model.prepaymentOptions) { option in
                prepaymentCard(option)
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.prepaymentPercent)
    }

    private func prepaymentCard(_ option: PrepaymentOption) -> some View {
        let isSelected = model.prepaymentPercent == option.percent

        return BookingChoiceCard(isSelected: isSelected) {
            model.selectPrepayment(option.percent)
        } content: {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack(spacing: PRVSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: PRVSpacing.xs) {
                            Text(option.title)
                                .prvStyle(.headline)
                            if option.grantsPriority {
                                PRVBadge("Priority", tint: Color.prv.gold)
                            }
                        }
                        Text(option.subtitle)
                            .prvStyle(.footnote)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    BookingSelectionMark(isSelected: isSelected)
                }

                if !option.benefits.isEmpty {
                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        ForEach(option.benefits) { benefit in
                            HStack(spacing: PRVSpacing.xs) {
                                Image(systemName: benefit.symbolName)
                                    .font(.caption)
                                    .foregroundStyle(tint(for: benefit.kind))
                                    .frame(width: 16)
                                    .accessibilityHidden(true)
                                Text(benefit.text)
                                    .prvStyle(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel(accessibilityLabel(for: option))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func tint(for kind: PrepaymentBenefit.Kind) -> Color {
        switch kind {
        case .discount: Color.prv.success
        case .points: Color.prv.accent
        case .cashback: Color.prv.gold
        case .priority: Color.prv.gold
        case .neutral: Color.prv.textSecondary
        }
    }

    private func accessibilityLabel(for option: PrepaymentOption) -> String {
        var label = "\(option.title), \(option.subtitle)"
        if !option.benefits.isEmpty {
            label += ". Benefits: " + option.benefits.map(\.text).joined(separator: ", ")
        }
        return label
    }

    // MARK: - Coupon

    private var couponCard: some View {
        @Bindable var model = model

        return PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text("Promo code")
                    .prvStyle(.headline)

                if let coupon = model.appliedCoupon {
                    HStack(spacing: PRVSpacing.xs) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.prv.success)
                            .accessibilityHidden(true)
                        Text("\(coupon.code) · \(BookingFormatting.discount(coupon.discount))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                        Spacer(minLength: PRVSpacing.xs)
                        Button("Remove") {
                            model.removeCoupon()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                        .accessibilityLabel("Remove promo code \(coupon.code)")
                    }
                    .padding(PRVSpacing.sm)
                    .background(Color.prv.success.opacity(0.10), in: PRVRadius.shape(PRVRadius.sm))
                } else {
                    HStack(spacing: PRVSpacing.xs) {
                        TextField("Enter a code", text: $model.couponCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isCouponFocused)
                            .onSubmit(applyCoupon)
                            .padding(PRVSpacing.sm)
                            .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                            .accessibilityLabel("Promo code")

                        Button {
                            isCouponFocused = false
                            applyCoupon()
                        } label: {
                            if model.isValidatingCoupon {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 44)
                            } else {
                                Text("Apply")
                            }
                        }
                        .buttonStyle(.prvGlass)
                        .disabled(model.couponCode.trimmed.isBlank || model.isValidatingCoupon)
                        .accessibilityLabel("Apply promo code")
                    }
                }
            }
        }
    }

    // MARK: - Totals

    private var totalsCard: some View {
        PRVGlassCard {
            VStack(spacing: PRVSpacing.xs) {
                BookingSummaryRow(label: "Treatments", value: model.servicesSubtotal.formatted)

                if !model.couponDiscount.isZero {
                    BookingSummaryRow(
                        label: "Promo code",
                        value: "−\(model.couponDiscount.formatted)",
                        tint: Color.prv.success
                    )
                }
                if !model.prepaymentDiscount.isZero {
                    BookingSummaryRow(
                        label: "Prepayment discount",
                        value: "−\(model.prepaymentDiscount.formatted)",
                        tint: Color.prv.success
                    )
                }

                Divider()

                BookingSummaryRow(
                    label: "Total",
                    value: model.orderTotal.formatted,
                    isProminent: true
                )
                BookingSummaryRow(
                    label: "Charged today",
                    value: model.dueToday.isZero ? "Nothing" : model.dueToday.formatted,
                    systemImage: "creditcard"
                )
                if !model.dueAtSalon.isZero {
                    BookingSummaryRow(
                        label: "At the salon",
                        value: model.dueAtSalon.formatted,
                        systemImage: "banknote"
                    )
                }
            }
        }
    }
}
