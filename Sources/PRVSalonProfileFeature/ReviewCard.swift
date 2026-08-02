import SwiftUI
import PRVModels
import PRVDesignSystem

/// One review: author with verified badge, stars, text, photo thumbnails,
/// a like button, a report-abuse menu, and the owner's response when the
/// salon has replied. Shared by the salon Reviews section and the
/// professional profile.
struct ReviewCard: View {
    let review: Review
    /// Name shown on the owner-response header, e.g. the salon name.
    let responderName: String
    let onToggleLike: () -> Void
    let onReport: () -> Void

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                header
                PRVRatingStars(rating: Double(review.rating))

                Text(review.text)
                    .prvStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !review.photoURLs.isEmpty {
                    photoThumbnails
                }

                HStack {
                    likeButton
                    Spacer()
                }

                if let response = review.ownerResponse {
                    ownerResponse(response)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: PRVSpacing.sm) {
            PRVAvatar(name: review.authorName, imageURL: review.authorAvatarURL, size: .medium)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: PRVSpacing.xxs) {
                    Text(review.authorName)
                        .prvStyle(.headline)
                        .lineLimit(1)
                    if review.isVerified {
                        PRVBadge("Verified", tint: Color.prv.success)
                    }
                }
                Text(ProfileFormatting.relativeDate(review.createdAt))
                    .prvStyle(.caption)
            }

            Spacer(minLength: PRVSpacing.xs)

            reportMenu
        }
    }

    /// Overflow menu with the report-abuse action.
    private var reportMenu: some View {
        Menu {
            Button(role: .destructive) {
                onReport()
            } label: {
                Label("Report Review", systemImage: "exclamationmark.bubble")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options for \(review.authorName)'s review")
    }

    // MARK: - Photos

    private var photoThumbnails: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PRVSpacing.xs) {
                ForEach(Array(review.photoURLs.enumerated()), id: \.offset) { index, url in
                    PRVAsyncImage(
                        url: url,
                        accessibilityLabel: "Review photo \(index + 1) of \(review.photoURLs.count)"
                    )
                    .frame(width: 72, height: 72)
                    .clipShape(PRVRadius.shape(PRVRadius.sm))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Like

    private var likeButton: some View {
        Button {
            onToggleLike()
        } label: {
            HStack(spacing: PRVSpacing.xxs) {
                Image(systemName: review.likedByMe ? "heart.fill" : "heart")
                    .foregroundStyle(review.likedByMe ? Color.prv.accent : Color.prv.textSecondary)
                    .symbolEffect(.bounce, value: review.likedByMe)
                Text("\(review.likeCount)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.prv.textSecondary)
            }
            .padding(.vertical, PRVSpacing.xxs)
            .padding(.horizontal, PRVSpacing.xs)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .prvAnimation(PRVMotion.quick, value: review.likedByMe)
        .accessibilityLabel(review.likedByMe ? "Unlike review" : "Like review")
        .accessibilityValue("\(review.likeCount) likes")
    }

    // MARK: - Owner response

    private func ownerResponse(_ response: String) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            HStack(spacing: PRVSpacing.xxs) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.prv.accent)
                    .accessibilityHidden(true)
                Text("Response from \(responderName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                if let respondedAt = review.ownerRespondedAt {
                    Text(ProfileFormatting.relativeDate(respondedAt))
                        .prvStyle(.caption)
                }
            }
            Text(response)
                .prvStyle(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PRVSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prv.accent.opacity(0.07), in: PRVRadius.shape(PRVRadius.md))
    }
}

#Preview("Review Card") {
    VStack(spacing: PRVSpacing.sm) {
        ForEach(PreviewData.reviews) { review in
            ReviewCard(
                review: review,
                responderName: PreviewData.salonLumiere.name,
                onToggleLike: {},
                onReport: {}
            )
        }
    }
    .padding(PRVSpacing.md)
    .background(Color.prv.canvas)
}
