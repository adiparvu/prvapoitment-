import AVKit
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Full-screen presentation of a photo or video sent in a conversation.
///
/// Photos are pinch-zoomable and pannable, with a double-tap to fit; videos
/// play in the system player. Both sit on a dimmed canvas with a floating
/// glass close control and the message's caption.
struct ChatMediaViewer: View {
    @Environment(\.dismiss) private var dismiss

    /// The media to present.
    let media: ChatMediaPreview

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch media.kind {
            case .photo:
                ZoomablePhoto(url: media.url)
            case .video:
                ChatVideoPlayer(url: media.url)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay(alignment: .bottom) { captionStrip }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button {
            PRVHaptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .padding(PRVSpacing.md)
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private var captionStrip: some View {
        if let caption = media.caption, !caption.isBlank {
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(PRVSpacing.sm)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.45))
                .accessibilityLabel("Caption: \(caption)")
        }
    }
}

/// The system player, started when it appears and paused when it leaves.
private struct ChatVideoPlayer: View {
    @State private var player: AVPlayer

    /// Creates a player for the movie at `url`.
    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea(edges: .bottom)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .accessibilityLabel("Video message")
    }
}

/// A pinch-to-zoom, drag-to-pan photo that always springs back into frame.
private struct ZoomablePhoto: View {
    let url: URL

    /// Largest magnification allowed.
    private static let maximumScale: CGFloat = 4

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        PRVAsyncImage(url: url, contentMode: .fit, accessibilityLabel: "Photo message")
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnification)
            .simultaneousGesture(pan)
            .onTapGesture(count: 2) { toggleZoom() }
            .prvAnimation(PRVMotion.gentle, value: scale)
            .prvAnimation(PRVMotion.gentle, value: offset)
            .accessibilityHint("Double tap to zoom, drag to pan")
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = clampedScale(committedScale * value.magnification)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1 { resetPan() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func toggleZoom() {
        PRVHaptics.tap()
        if scale > 1 {
            scale = 1
            committedScale = 1
            resetPan()
        } else {
            scale = 2
            committedScale = 2
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(Self.maximumScale, max(1, value))
    }
}

#Preview("Media Viewer — Photo") {
    ChatMediaViewer(
        media: ChatMediaPreview(
            url: URL(string: "https://picsum.photos/seed/prvchat/900/1200") ?? URL(filePath: "/preview.jpg"),
            kind: .photo,
            caption: "Inspiration for Thursday — soft honey ends."
        )
    )
}
