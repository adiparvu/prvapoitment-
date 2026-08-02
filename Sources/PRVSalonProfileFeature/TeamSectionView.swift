import SwiftUI
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The Team section: tappable professional cards that push the shared
/// `.professional(id)` route on the `AppRouter`.
struct TeamSectionView: View {
    @Environment(AppRouter.self) private var router

    let professionals: [Professional]

    var body: some View {
        if professionals.isEmpty {
            PRVEmptyState(
                systemImage: "person.2",
                title: "No team members yet",
                message: "This salon hasn't introduced its team. Their specialists will appear here."
            )
        } else {
            VStack(spacing: PRVSpacing.sm) {
                ForEach(professionals) { professional in
                    ProfessionalCard(professional: professional) {
                        router.push(.professional(professional.id))
                    }
                }
            }
        }
    }
}

/// One professional in the team list: avatar, name, title, rating, and
/// their top specialties.
struct ProfessionalCard: View {
    let professional: Professional
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard {
                HStack(spacing: PRVSpacing.sm) {
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

                        HStack(spacing: PRVSpacing.xxs) {
                            PRVRatingStars(rating: professional.rating)
                            Text("\(ProfileFormatting.rating(professional.rating)) (\(professional.reviewCount))")
                                .prvStyle(.footnote)
                        }

                        if !professional.specialties.isEmpty {
                            PRVFlowLayout(spacing: PRVSpacing.xxs) {
                                ForEach(professional.specialties.prefix(3), id: \.self) { specialty in
                                    PRVTag(specialty, systemImage: "sparkles", tint: Color.prv.accent)
                                }
                            }
                        }
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    PRVListRowChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens their profile")
    }

    private var accessibilityLabel: String {
        "\(professional.displayName), \(professional.title), rated \(ProfileFormatting.rating(professional.rating)) out of 5"
    }
}

#Preview("Team Section") {
    ScrollView {
        TeamSectionView(professionals: PreviewData.professionals)
            .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}
