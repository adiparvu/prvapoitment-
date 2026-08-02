import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Captures a handwritten signature against a consent document.
///
/// Strokes are collected as point paths and drawn with `Canvas`, so the pad is
/// pure SwiftUI and stays smooth at 120 Hz. Confirming writes `signedAt`
/// through `saveConsentForm`; the drawn image itself is shown for confirmation
/// and then discarded, because the repository has no upload endpoint for it yet.
struct SignatureCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let title: String
    let version: String
    let clientName: String
    /// Persists the signature; the sheet dismisses once it returns.
    let sign: @MainActor () async -> Void

    @State private var strokes: [SignatureStroke] = []
    @State private var current = SignatureStroke()
    @State private var hasAgreed = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                documentSummary
                signaturePad
                agreement

                Spacer(minLength: 0)

                Button("Sign & Save") { submit() }
                    .buttonStyle(.prvPrimary)
                    .disabled(!canSign || isSaving)
                    .accessibilityHint("Records the signature against \(title)")
            }
            .padding(PRVSpacing.lg)
            .background(Color.prv.canvas)
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        PRVHaptics.tap()
                        strokes = []
                        current = SignatureStroke()
                    }
                    .disabled(strokes.isEmpty && current.points.isEmpty)
                    .accessibilityLabel("Clear signature")
                }
            }
        }
    }

    // MARK: - Sections

    private var documentSummary: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(title)
                .prvStyle(.headline)
            Text("Version \(version) · \(clientName)")
                .prvStyle(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard()
        .accessibilityElement(children: .combine)
    }

    private var signaturePad: some View {
        // Snapshot the strokes into a local value so the renderer closure
        // captures plain `Sendable` data rather than the view's state.
        let drawn = strokes + [current]

        return VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Canvas { context, size in
                for stroke in drawn {
                    guard let path = stroke.path else { continue }
                    context.stroke(
                        path,
                        with: .color(Color.prv.textPrimary),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                }
                // Baseline the client signs on.
                var baseline = Path()
                baseline.move(to: CGPoint(x: PRVSpacing.lg, y: size.height - PRVSpacing.xl))
                baseline.addLine(to: CGPoint(x: size.width - PRVSpacing.lg, y: size.height - PRVSpacing.xl))
                context.stroke(
                    baseline,
                    with: .color(Color.prv.separator),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }
            .frame(height: 220)
            .background {
                if reduceTransparency {
                    PRVRadius.shape(PRVRadius.lg).fill(Color.prv.surface)
                } else {
                    PRVRadius.shape(PRVRadius.lg).fill(.ultraThinMaterial)
                }
            }
            .overlay {
                PRVRadius.shape(PRVRadius.lg)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay(alignment: .bottom) {
                if isEmpty {
                    Text("Sign above the line")
                        .prvStyle(.caption)
                        .padding(.bottom, PRVSpacing.sm)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        current.points.append(value.location)
                    }
                    .onEnded { _ in
                        if current.points.count > 1 {
                            strokes.append(current)
                        }
                        current = SignatureStroke()
                    }
            )
            .accessibilityLabel("Signature pad")
            .accessibilityHint("Draw the client's signature with a finger or stylus")
            .accessibilityValue(isEmpty ? "Empty" : "\(strokes.count) strokes captured")

            Text("Drawn on device. Only the signing timestamp and document version leave this screen.")
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agreement: some View {
        Toggle(isOn: $hasAgreed) {
            Text("\(clientName) has read and agreed to this document.")
                .font(.subheadline)
                .foregroundStyle(Color.prv.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Color.prv.accent)
        .prvGlassCard()
    }

    // MARK: - State

    private var isEmpty: Bool {
        strokes.isEmpty && current.points.count < 2
    }

    private var canSign: Bool {
        !isEmpty && hasAgreed
    }

    private func submit() {
        guard canSign, !isSaving else { return }
        isSaving = true
        Task {
            await sign()
            isSaving = false
            dismiss()
        }
    }
}

/// One continuous pen stroke on the signature pad.
struct SignatureStroke: Equatable, Sendable {
    var points: [CGPoint] = []

    /// The stroke as a drawable path, or `nil` when there is nothing to draw.
    var path: Path? {
        guard points.count > 1 else { return nil }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

// MARK: - Previews

#Preview("Signature") {
    SignatureCaptureSheet(
        title: "Colour Service Consent",
        version: "2.1",
        clientName: "Sofia Laurent"
    ) {}
}

#Preview("Signature — Dark") {
    SignatureCaptureSheet(
        title: "Patch Test Declaration",
        version: "1.4",
        clientName: "Sofia Laurent"
    ) {}
        .preferredColorScheme(.dark)
}
