import SwiftUI
import PRVFoundation
import PRVModels
import PRVDesignSystem

/// The full filter sheet: categories, amenities, availability windows,
/// minimum rating, budget, languages, and verified-only — all editing a
/// draft `SalonSearchQuery` that is committed with "Show Results" or wiped
/// with "Clear All".
struct DiscoverFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SalonSearchQuery
    private let onApply: (SalonSearchQuery) -> Void

    /// Rating floors offered as chips.
    private static let ratingChoices: [Double] = [4.0, 4.5, 4.8]
    /// Budget slider bounds (per service, in the platform currency).
    private static let priceRange: ClosedRange<Double> = 20...300

    init(query: SalonSearchQuery, onApply: @escaping (SalonSearchQuery) -> Void) {
        self._draft = State(initialValue: query)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                    categoriesSection
                    amenitiesSection
                    availabilitySection
                    ratingSection
                    priceSection
                    languagesSection
                    verifiedSection
                }
                .padding(.horizontal, PRVSpacing.lg)
                .padding(.vertical, PRVSpacing.md)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        PRVHaptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.prv.textSecondary.opacity(0.7))
                    }
                    .accessibilityLabel("Close filters")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var categoriesSection: some View {
        filterSection("Categories") {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(BusinessCategory.allCases, id: \.self) { category in
                    PRVChip(
                        category.displayName,
                        systemImage: category.symbolName,
                        isSelected: draft.categories.contains(category)
                    ) {
                        toggle(category, in: \.categories)
                    }
                }
            }
        }
    }

    private var amenitiesSection: some View {
        filterSection("Amenities") {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(SalonAmenity.allCases, id: \.self) { amenity in
                    PRVChip(
                        amenity.displayName,
                        systemImage: amenity.symbolName,
                        isSelected: draft.amenities.contains(amenity)
                    ) {
                        toggle(amenity, in: \.amenities)
                    }
                }
            }
        }
    }

    private var availabilitySection: some View {
        filterSection("Availability") {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(SalonSearchQuery.AvailabilityWindow.allCases, id: \.self) { window in
                    PRVChip(
                        window.displayName,
                        systemImage: window.symbolName,
                        isSelected: draft.availability == window
                    ) {
                        draft.availability = window
                    }
                }
            }
        }
    }

    private var ratingSection: some View {
        filterSection("Minimum Rating") {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                PRVChip("Any", isSelected: draft.minRating == nil) {
                    draft.minRating = nil
                }
                ForEach(Self.ratingChoices, id: \.self) { rating in
                    PRVChip(
                        "\(rating.formatted(.number.precision(.fractionLength(1))))+",
                        systemImage: "star.fill",
                        isSelected: draft.minRating == rating
                    ) {
                        draft.minRating = rating
                    }
                }
            }
        }
    }

    private var priceSection: some View {
        filterSection("Budget") {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text(priceLabel)
                    .prvStyle(.subheadline)

                Slider(
                    value: priceBinding,
                    in: Self.priceRange,
                    step: 10
                ) {
                    Text("Maximum price")
                } minimumValueLabel: {
                    Text(Money(Decimal(Self.priceRange.lowerBound)).formatted)
                        .prvStyle(.caption)
                } maximumValueLabel: {
                    Text("Any")
                        .prvStyle(.caption)
                }
                .tint(Color.prv.accent)
                .accessibilityValue(priceLabel)
            }
        }
    }

    private var languagesSection: some View {
        filterSection("Languages Spoken") {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                ForEach(DiscoverLanguages.choices, id: \.self) { code in
                    PRVChip(
                        DiscoverLanguages.displayName(for: code),
                        isSelected: draft.languages.contains(code)
                    ) {
                        toggle(code, in: \.languages)
                    }
                }
            }
        }
    }

    private var verifiedSection: some View {
        Toggle(isOn: $draft.verifiedOnly) {
            HStack(spacing: PRVSpacing.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.body)
                    .foregroundStyle(Color.prv.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verified only")
                        .prvStyle(.headline)
                    Text("Businesses with confirmed identity and credentials")
                        .prvStyle(.caption)
                }
            }
        }
        .tint(Color.prv.accent)
        .prvGlassCard()
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: PRVSpacing.sm) {
            Button {
                PRVHaptics.warning()
                clearAll()
            } label: {
                Text("Clear All")
            }
            .buttonStyle(.prvGlass)
            .accessibilityLabel("Clear all filters")

            Button {
                PRVHaptics.impact()
                onApply(draft)
                dismiss()
            } label: {
                Text(applyTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prvPrimary)
            .accessibilityLabel(applyTitle)
        }
        .padding(.horizontal, PRVSpacing.lg)
        .padding(.vertical, PRVSpacing.sm)
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func filterSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            Text(title)
                .prvStyle(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Toggles membership of a value in one of the draft's array filters.
    private func toggle<Value: Equatable>(
        _ value: Value,
        in keyPath: WritableKeyPath<SalonSearchQuery, [Value]>
    ) {
        if let index = draft[keyPath: keyPath].firstIndex(of: value) {
            draft[keyPath: keyPath].remove(at: index)
        } else {
            draft[keyPath: keyPath].append(value)
        }
    }

    /// Bridges the optional `Decimal` max price to the slider's `Double`;
    /// the slider's top end means "no limit".
    private var priceBinding: Binding<Double> {
        Binding(
            get: { draft.maxPrice?.doubleValue ?? Self.priceRange.upperBound },
            set: { newValue in
                draft.maxPrice = newValue >= Self.priceRange.upperBound ? nil : Decimal(newValue)
            }
        )
    }

    private var priceLabel: String {
        if let maxPrice = draft.maxPrice {
            return "Up to \(Money(maxPrice).formatted) per service"
        }
        return "Any budget"
    }

    private var applyTitle: String {
        draft.activeFilterCount > 0 ? "Show Results · \(draft.activeFilterCount)" : "Show Results"
    }

    /// Resets every structured filter, keeping text and sort untouched.
    private func clearAll() {
        var cleared = SalonSearchQuery()
        cleared.text = draft.text
        cleared.sort = draft.sort
        draft = cleared
    }
}

#Preview("Filter Sheet") {
    DiscoverFilterSheet(query: SalonSearchQuery(categories: [.hairSalon], verifiedOnly: true)) { _ in }
}
