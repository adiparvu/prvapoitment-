import SwiftUI
import Vision
import VisionKit
import PRVDesignSystem

/// Live barcode scanning for the stock desk.
///
/// Wraps VisionKit's `DataScannerViewController`, which is the only part of the
/// hub that isn't pure SwiftUI — there is no SwiftUI equivalent. Devices without
/// the required camera/Neural Engine combination (and the Simulator) get a
/// graceful fallback that points at the manual barcode field instead of a black
/// rectangle. The app's `Info.plist` must carry `NSCameraUsageDescription`.
struct BarcodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Delivered once, with the first barcode payload recognized.
    let onScan: @MainActor (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if BarcodeScanner.isAvailable {
                    scanner
                } else {
                    unsupported
                }
            }
            .background(Color.prv.canvas)
            .navigationTitle("Scan Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Scanner

    private var scanner: some View {
        BarcodeScannerRepresentable { payload in
            PRVHaptics.success()
            onScan(payload)
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) {
            Text("Hold the camera over the product's barcode.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.prv.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.vertical, PRVSpacing.sm)
                .padding(.horizontal, PRVSpacing.md)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                .prvSoftShadow()
                .padding(.bottom, PRVSpacing.xxl)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Live barcode scanner")
        .accessibilityHint("Point the camera at a barcode to look the product up")
    }

    // MARK: Fallback

    private var unsupported: some View {
        PRVEmptyState(
            systemImage: "camera.metering.unknown",
            title: "Scanning isn't available here",
            message: "This device can't run live barcode scanning. Type the barcode into the lookup field instead — it works exactly the same.",
            actionTitle: "Enter It Manually"
        ) {
            dismiss()
        }
    }
}

// MARK: - Availability

/// Whether the current device can run VisionKit's live scanner.
enum BarcodeScanner {
    /// `isSupported` covers the hardware; `isAvailable` also covers camera
    /// permission and device restrictions at this moment.
    @MainActor
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// The retail symbologies worth scanning in a salon: product barcodes plus
    /// QR and Data Matrix for supplier labels.
    static var symbologies: [VNBarcodeSymbology] {
        [.ean13, .ean8, .upce, .code128, .code39, .itf14, .qr, .dataMatrix]
    }
}

// MARK: - Representable

/// The `UIViewControllerRepresentable` bridge around `DataScannerViewController`.
struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    /// Called with the first recognized payload; further scans are ignored so
    /// one pass of the camera can't fire the lookup repeatedly.
    let onScan: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: BarcodeScanner.symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        guard !controller.isScanning else { return }
        try? controller.startScanning()
    }

    static func dismantleUIViewController(
        _ controller: DataScannerViewController,
        coordinator: Coordinator
    ) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    /// Bridges VisionKit's delegate callbacks — which always arrive on the main
    /// thread — back into SwiftUI state.
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: @MainActor (String) -> Void
        private var hasDelivered = false

        init(onScan: @escaping @MainActor (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            deliver(from: addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            deliver(from: [item])
        }

        private func deliver(from items: [RecognizedItem]) {
            guard !hasDelivered else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      !payload.isEmpty
                else { continue }
                hasDelivered = true
                MainActor.assumeIsolated { onScan(payload) }
                return
            }
        }
    }
}
