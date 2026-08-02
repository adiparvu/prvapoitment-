import SwiftUI

/// PRV type scale, built on SF Pro with Dynamic Type support.
public enum PRVTextStyle {
    /// Hero numerals & splash moments (serif-free, rounded large title).
    case display
    /// Screen titles.
    case largeTitle
    case title
    case title2
    case headline
    case body
    case callout
    case subheadline
    case footnote
    case caption

    var font: Font {
        switch self {
        case .display: .system(.largeTitle, design: .rounded, weight: .bold)
        case .largeTitle: .largeTitle.weight(.bold)
        case .title: .title.weight(.semibold)
        case .title2: .title2.weight(.semibold)
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption
        }
    }

    var color: Color {
        switch self {
        case .subheadline, .footnote, .caption: .prv.textSecondary
        default: .prv.textPrimary
        }
    }
}

extension View {
    /// Applies the PRV type scale: `Text("Hello").prvStyle(.title)`.
    public func prvStyle(_ style: PRVTextStyle) -> some View {
        font(style.font).foregroundStyle(style.color)
    }
}
