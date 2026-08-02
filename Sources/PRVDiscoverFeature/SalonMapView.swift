import SwiftUI
import MapKit
import PRVModels
import PRVDesignSystem

/// MapKit view of the current search results: one branded annotation per
/// salon at its address coordinate. Tapping a pin opens the salon profile.
/// The camera frames all annotations automatically.
struct SalonMapView: View {
    let salons: [Salon]
    let onSelect: (Salon) -> Void

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            ForEach(salons) { salon in
                Annotation(coordinate: salon.address.coordinate.clCoordinate) {
                    SalonMapPin(salon: salon) {
                        onSelect(salon)
                    }
                } label: {
                    Text(salon.name)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .accessibilityLabel("Map of \(salons.count) salons")
    }
}

/// Branded map pin: category glyph on the accent gradient with a small
/// rating capsule beneath it.
struct SalonMapPin: View {
    let salon: Salon
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            VStack(spacing: PRVSpacing.xxs) {
                ZStack {
                    Circle()
                        .fill(Color.prv.accentGradient)
                        .frame(width: 36, height: 36)
                        .prvSoftShadow()
                    Image(systemName: salon.categories.first?.symbolName ?? "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.prv.textOnAccent)
                }

                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.prv.gold)
                    Text(salon.rating.formatted(.number.precision(.fractionLength(1))))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.prv.textPrimary)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, PRVSpacing.xxs + 2)
                .prvGlassEffect()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(salon.name), rated \(salon.rating.formatted(.number.precision(.fractionLength(1)))) out of 5"
        )
        .accessibilityHint("Opens the salon profile")
    }
}

#Preview("Salon Map") {
    SalonMapView(salons: PreviewData.salons) { _ in }
}
