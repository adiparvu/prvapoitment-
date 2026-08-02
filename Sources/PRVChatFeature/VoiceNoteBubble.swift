import AVFoundation
import Observation
import SwiftUI
import PRVDesignSystem
import PRVModels

/// Plays one voice note. Each bubble owns its own player, so a note keeps its
/// own progress and stops cleanly when the bubble scrolls away.
@Observable
@MainActor
final class VoiceNotePlayer {
    /// Whether audio is currently running.
    private(set) var isPlaying = false
    /// Playback position through the note, from 0 to 1.
    private(set) var progress: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// How often the waveform's played portion is refreshed.
    private static let tick: Duration = .milliseconds(80)

    /// Creates an idle player.
    init() {}

    /// Starts or resumes the note at `url`.
    func play(url: URL) {
        activateAudioSession()
        if player == nil {
            player = AVPlayer(url: url)
        }
        player?.play()
        isPlaying = true
        startTicking()
    }

    /// Pauses without losing the current position.
    func pause() {
        player?.pause()
        isPlaying = false
        cancelTicking()
    }

    /// Toggles playback for the note at `url`.
    func toggle(url: URL) {
        if isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    /// Releases the player entirely — call when the bubble disappears.
    func stop() {
        player?.pause()
        player = nil
        isPlaying = false
        progress = 0
        cancelTicking()
    }

    /// Routes voice notes to the speaker so the silent switch does not
    /// swallow a message the client deliberately tapped.
    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }

    /// Drives progress with structured concurrency — no timers, no queues.
    private func startTicking() {
        cancelTicking()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VoiceNotePlayer.tick)
                guard let self, !Task.isCancelled else { return }
                self.advance()
                if !self.isPlaying { return }
            }
        }
    }

    private func cancelTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Samples the player clock and rewinds once the note finishes.
    private func advance() {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite else { return }

        progress = min(1, max(0, current / duration))
        if progress >= 0.999 {
            player.pause()
            player.seek(to: .zero)
            isPlaying = false
            progress = 0
            cancelTicking()
        }
    }
}

/// A voice note rendered as a play control, a waveform whose played portion
/// fills in, and the note's duration.
struct VoiceNoteContent: View {
    /// Where the audio lives.
    let url: URL
    /// Length of the note in seconds, as recorded.
    let durationSeconds: Int
    /// Whether the bubble belongs to the signed-in user.
    let isMine: Bool

    /// Pre-computed so no waveform maths happens inside `body`.
    private let bars: [CGFloat]

    @State private var player = VoiceNotePlayer()

    /// Creates a voice-note bubble.
    /// - Parameters:
    ///   - url: Location of the audio.
    ///   - durationSeconds: Recorded length of the note.
    ///   - seed: Stable string (the message ID) fixing the waveform shape.
    ///   - isMine: Whether the note was sent by the signed-in user.
    init(url: URL, durationSeconds: Int, seed: String, isMine: Bool) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.isMine = isMine
        self.bars = VoiceWaveform.bars(for: seed)
    }

    private var tint: Color { isMine ? Color.prv.textOnAccent : Color.prv.accent }
    private var trackTint: Color {
        isMine ? Color.prv.textOnAccent.opacity(0.35) : Color.prv.textSecondary.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            Button {
                PRVHaptics.tap()
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(isMine ? Color.prv.accent : Color.prv.textOnAccent)
                    .frame(width: 32, height: 32)
                    .background(
                        isMine
                            ? AnyShapeStyle(Color.prv.textOnAccent)
                            : AnyShapeStyle(Color.prv.accentGradient),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause voice message" : "Play voice message")

            waveform

            Text(ChatFormat.voiceDuration(seconds: durationSeconds))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isMine ? Color.prv.textOnAccent.opacity(0.85) : Color.prv.textSecondary)
        }
        .padding(.vertical, PRVSpacing.xs)
        .padding(.horizontal, PRVSpacing.sm)
        .onDisappear { player.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice message, \(ChatFormat.spokenVoiceDuration(seconds: durationSeconds))")
    }

    /// Bars fill with the playback tint as the note progresses.
    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { index in
                let threshold = Double(index + 1) / Double(bars.count)
                Capsule()
                    .fill(player.progress >= threshold ? tint : trackTint)
                    .frame(width: 2.5, height: 20 * bars[index])
            }
        }
        .frame(height: 22)
        .prvAnimation(PRVMotion.quick, value: player.progress)
        .accessibilityHidden(true)
    }
}

/// Deterministic waveform generation: the same note always draws the same
/// silhouette, on every device and every launch.
enum VoiceWaveform {
    /// Number of bars in a waveform.
    static let barCount = 30

    /// Amplitudes in the 0.25…1 range derived from a stable seed.
    static func bars(for seed: String, count: Int = barCount) -> [CGFloat] {
        var state = UInt64(5_381)
        for byte in seed.utf8 {
            state = (state &* 33) &+ UInt64(byte)
        }
        state |= 1

        return (0..<count).map { _ in
            // Knuth's LCG — cheap, deterministic, and well distributed.
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let normalized = CGFloat((state >> 33) % 1_000) / 1_000
            return 0.25 + normalized * 0.75
        }
    }
}

#Preview("Voice Note") {
    VStack(spacing: PRVSpacing.md) {
        VoiceNoteContent(
            url: URL(filePath: "/preview/note-mine.m4a"),
            durationSeconds: 42,
            seed: "preview-mine",
            isMine: true
        )
        .background(Color.prv.accentGradient, in: PRVRadius.shape(PRVRadius.lg))

        VoiceNoteContent(
            url: URL(filePath: "/preview/note-theirs.m4a"),
            durationSeconds: 8,
            seed: "preview-theirs",
            isMine: false
        )
        .background(.ultraThinMaterial, in: PRVRadius.shape(PRVRadius.lg))
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}
