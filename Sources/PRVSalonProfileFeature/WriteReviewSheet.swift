import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The "Write a review" sheet: interactive star input, a free-text
/// experience field, and submission through the salon repository. Requires
/// a signed-in user with the review permission; guests see a friendly
/// sign-in prompt instead of the form.
struct WriteReviewSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let model: SalonProfileModel
    let salonName: String

    @State private var rating = 0
    @State private var text = ""
    @State private var isSubmitting = false
    @FocusState private var isTextFocused: Bool

    /// Minimum characters for a useful review.
    private let minimumLength = 10

    private var canSubmit: Bool {
        rating > 0 && text.trimmed.count >= minimumLength && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Group {
                if let user = session.currentUser, session.can(.review) {
                    form(author: user)
                } else {
                    PRVEmptyState(
                        systemImage: "person.crop.circle.badge.questionmark",
                        title: "Sign in to review",
                        message: "Reviews come from real clients. Sign in to share your experience at \(salonName)."
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .background(Color.prv.canvas)
            .navigationTitle("Write a Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Form

    private func form(author: User) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    Text("How was \(salonName)?")
                        .prvStyle(.title2)

                    PRVRatingStars(selection: $rating)

                    if rating > 0 {
                        Text(ratingCaption)
                            .prvStyle(.footnote)
                            .transition(.opacity)
                    }
                }
                .prvAnimation(PRVMotion.quick, value: rating)

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Tell us more")
                        .prvStyle(.headline)

                    TextEditor(text: $text)
                        .focused($isTextFocused)
                        .frame(minHeight: 140)
                        .padding(PRVSpacing.xs)
                        .scrollContentBackground(.hidden)
                        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.md))
                        .overlay {
                            PRVRadius.shape(PRVRadius.md)
                                .strokeBorder(Color.prv.separator, lineWidth: 0.5)
                        }
                        .accessibilityLabel("Your review")
                        .accessibilityHint("Describe your experience in at least \(minimumLength) characters")

                    Text(lengthHint)
                        .prvStyle(.caption)
                }

                Button {
                    Task { await submit(author: author) }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .tint(Color.prv.textOnAccent)
                    } else {
                        Text("Submit Review")
                    }
                }
                .buttonStyle(.prvPrimary)
                .disabled(!canSubmit)
                .accessibilityLabel(isSubmitting ? "Submitting review" : "Submit review")
            }
            .padding(PRVSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var ratingCaption: String {
        switch rating {
        case 5: "Amazing — a five-star experience"
        case 4: "Great visit"
        case 3: "It was okay"
        case 2: "Below expectations"
        default: "We're sorry to hear that"
        }
    }

    private var lengthHint: String {
        let remaining = minimumLength - text.trimmed.count
        return remaining > 0
            ? "At least \(remaining) more characters"
            : "\(text.trimmed.count) characters"
    }

    // MARK: - Submission

    private func submit(author: User) async {
        guard canSubmit else { return }
        isSubmitting = true
        let succeeded = await model.submitReview(
            rating: rating,
            text: text.trimmed,
            author: author,
            using: deps
        )
        isSubmitting = false
        if succeeded {
            dismiss()
        }
    }
}

#Preview("Write Review") {
    WriteReviewSheet(
        model: SalonProfileModel(salonID: PreviewData.salonLumiere.id),
        salonName: PreviewData.salonLumiere.name
    )
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}

#Preview("Write Review — Signed Out") {
    WriteReviewSheet(
        model: SalonProfileModel(salonID: PreviewData.salonLumiere.id),
        salonName: PreviewData.salonLumiere.name
    )
    .environment(UserSession())
    .environment(AppRouter())
}
