import SwiftUI

/// A Liquid Glass search input: magnifier icon, prompt, and a clear button
/// that appears while there is text. Submits with the keyboard's Search key.
///
/// ```swift
/// PRVSearchField(text: $model.query, prompt: "Search salons, treatments…") {
///     await model.search()
/// }
/// ```
public struct PRVSearchField: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isFocused: Bool

    @Binding private var text: String
    private let prompt: String
    private let onSubmit: (() -> Void)?

    /// Creates a search field.
    /// - Parameters:
    ///   - text: Bound query text.
    ///   - prompt: Placeholder shown while empty. Defaults to "Search".
    ///   - onSubmit: Called when the user taps the keyboard's Search key.
    public init(
        text: Binding<String>,
        prompt: String = "Search",
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(Color.prv.textSecondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .foregroundStyle(Color.prv.textPrimary)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button {
                    PRVHaptics.tap()
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.prv.textSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(.vertical, PRVSpacing.sm)
        .padding(.horizontal, PRVSpacing.md)
        .background {
            if reduceTransparency {
                Capsule().fill(Color.prv.surface)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(
                isFocused ? Color.prv.accent.opacity(0.5) : .white.opacity(0.12),
                lineWidth: isFocused ? 1 : 0.5
            )
        }
        .prvAnimation(PRVMotion.quick, value: text.isEmpty)
        .prvAnimation(PRVMotion.quick, value: isFocused)
    }
}

#Preview("Search Field — Light") {
    @Previewable @State var empty = ""
    @Previewable @State var filled = "Balayage"
    VStack(spacing: PRVSpacing.md) {
        PRVSearchField(text: $empty, prompt: "Search salons, treatments…")
        PRVSearchField(text: $filled)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Search Field — Dark") {
    @Previewable @State var query = "Gel manicure"
    PRVSearchField(text: $query, prompt: "Search salons, treatments…")
        .padding(PRVSpacing.lg)
        .background(Color.prv.canvas)
        .preferredColorScheme(.dark)
}
