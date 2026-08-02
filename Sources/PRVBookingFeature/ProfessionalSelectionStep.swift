import SwiftUI
import PRVDesignSystem
import PRVModels

/// Step 2 — who performs the treatment. "Any available" is offered first
/// because it unlocks the widest availability; every artist who can perform
/// the full selection follows, with rating, experience, and specialties.
struct ProfessionalSelectionStepView: View {
    let model: BookingFlowModel

    private var professionals: [Professional] { model.eligibleProfessionals }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            PRVSectionHeader(
                "Your artist",
                subtitle: professionals.isEmpty
                    ? "This salon assigns the best-suited artist for you"
                    : subtitle
            )

            anyAvailableCard

            ForEach(professionals) { professional in
                professionalCard(professional)
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.professionalID)
    }

    private var subtitle: String {
        professionals.count == 1
            ? "1 artist performs everything you picked"
            : "\(professionals.count) artists perform everything you picked"
    }

    // MARK: - Any available

    private var anyAvailableCard: some View {
        BookingChoiceCard(isSelected: model.professionalID == nil) {
            model.selectProfessional(nil)
        } content: {
            HStack(spacing: PRVSpacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.prv.accent.opacity(0.12))
                    Image(systemName: "wand.and.sparkles")
                        .font(.title3)
                        .foregroundStyle(Color.prv.accentGradient)
                }
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    HStack(spacing: PRVSpacing.xs) {
                        Text("Any available artist")
                            .prvStyle(.headline)
                        PRVBadge("Most times", tint: Color.prv.gold)
                    }
                    Text("We match you with the best-suited artist free at your chosen time.")
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: PRVSpacing.xs)

                BookingSelectionMark(isSelected: model.professionalID == nil)
            }
        }
        .accessibilityLabel("Any available artist")
        .accessibilityHint("Opens the widest choice of times")
        .accessibilityAddTraits(model.professionalID == nil ? [.isSelected] : [])
    }

    // MARK: - Professional

    private func professionalCard(_ professional: Professional) -> some View {
        let isSelected = model.professionalID == professional.id

        return BookingChoiceCard(isSelected: isSelected) {
            model.selectProfessional(professional)
        } content: {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack(spacing: PRVSpacing.md) {
                    PRVAvatar(
                        name: professional.displayName,
                        imageURL: professional.photoURL,
                        size: .large
                    )

                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        Text(professional.displayName)
                            .prvStyle(.headline)
                        Text(professional.title)
                            .prvStyle(.subheadline)

                        HStack(spacing: PRVSpacing.xs) {
                            PRVRatingStars(rating: professional.rating)
                            Text("\(BookingFormatting.rating(professional.rating)) (\(professional.reviewCount))")
                                .prvStyle(.caption)
                        }
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    BookingSelectionMark(isSelected: isSelected)
                }

                if !professional.specialties.isEmpty {
                    PRVFlowLayout(spacing: PRVSpacing.xxs) {
                        ForEach(professional.specialties, id: \.self) { specialty in
                            PRVTag(specialty, systemImage: "sparkles", tint: Color.prv.accent)
                        }
                    }
                }

                HStack(spacing: PRVSpacing.sm) {
                    if professional.yearsOfExperience > 0 {
                        Label(
                            "\(professional.yearsOfExperience) yrs experience",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .prvStyle(.caption)
                        .labelStyle(.titleAndIcon)
                    }
                    if let minutes = professional.averageResponseMinutes {
                        Label("Replies in ~\(minutes) min", systemImage: "bubble.left")
                            .prvStyle(.caption)
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityLabel(accessibilityLabel(for: professional))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func accessibilityLabel(for professional: Professional) -> String {
        var label = "\(professional.displayName), \(professional.title)"
        if professional.reviewCount > 0 {
            label += ", rated \(BookingFormatting.rating(professional.rating)) from \(professional.reviewCount) reviews"
        }
        if !professional.specialties.isEmpty {
            label += ", specialties: \(professional.specialties.joined(separator: ", "))"
        }
        return label
    }
}
