import SwiftUI

/// A circular avatar: remote photo when available, otherwise the person's
/// initials on the brand gradient. Photo loading shows a shimmering circle;
/// load failures fall back to initials so the avatar never looks broken.
///
/// ```swift
/// PRVAvatar(name: professional.displayName, imageURL: professional.avatarURL, size: .large)
/// ```
public struct PRVAvatar: View {
    /// Semantic avatar sizes used across the platform.
    public enum Size: Sendable {
        /// 28pt — inline mentions, compact rows.
        case small
        /// 44pt — list rows, chat.
        case medium
        /// 64pt — profile headers, cards.
        case large
        /// 96pt — profile hero.
        case xLarge
        /// Custom diameter in points.
        case custom(CGFloat)

        var diameter: CGFloat {
            switch self {
            case .small: 28
            case .medium: 44
            case .large: 64
            case .xLarge: 96
            case .custom(let value): value
            }
        }
    }

    private let name: String
    private let imageURL: URL?
    private let size: Size

    /// Creates an avatar.
    /// - Parameters:
    ///   - name: Full display name; used for initials and the VoiceOver label.
    ///   - imageURL: Optional profile photo URL.
    ///   - size: Avatar size. Defaults to `.medium` (44pt).
    public init(name: String, imageURL: URL? = nil, size: Size = .medium) {
        self.name = name
        self.imageURL = imageURL
        self.size = size
    }

    public var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        Circle()
                            .fill(Color.prv.textPrimary.opacity(0.08))
                            .prvShimmer()
                    case .failure:
                        initialsView
                    @unknown default:
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isImage)
    }

    /// Initials rendered on the brand gradient.
    private var initialsView: some View {
        ZStack {
            Color.prv.accentGradient
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size.diameter * 0.42))
                    .foregroundStyle(Color.prv.textOnAccent)
            } else {
                Text(initials)
                    .font(.system(size: size.diameter * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.prv.textOnAccent)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    /// First letter of the first and last name components, e.g. "Sofia Laurent" → "SL".
    private var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let first = words.first?.first.map(String.init) ?? ""
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (first + last).uppercased()
    }
}

#Preview("Avatar — Light") {
    HStack(spacing: PRVSpacing.md) {
        PRVAvatar(name: "Sofia Laurent", size: .small)
        PRVAvatar(name: "Amélie Dubois", size: .medium)
        PRVAvatar(name: "Noor", size: .large)
        PRVAvatar(name: "", size: .large)
        PRVAvatar(
            name: "Emma Verhoeven",
            imageURL: URL(string: "https://picsum.photos/seed/avatar/200"),
            size: .xLarge
        )
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Avatar — Dark") {
    HStack(spacing: PRVSpacing.md) {
        PRVAvatar(name: "Sofia Laurent", size: .small)
        PRVAvatar(name: "Amélie Dubois", size: .medium)
        PRVAvatar(name: "Noor", size: .large)
        PRVAvatar(name: "", size: .large)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
