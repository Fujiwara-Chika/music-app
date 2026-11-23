import SwiftUI

/// Bottom transport strip: playback buttons, elapsed time, seek slider and the
/// duration / shuffle / volume cluster.
///
/// `RootView` already draws the 1px `palette.separator` line above this view, so the
/// bar itself only contributes its background.
struct TransportBar: View {
    /// The clock ticks 30×/s; binding to it here keeps that cost inside this bar
    /// instead of redrawing the whole window.
    @EnvironmentObject private var clock: ProgressClock
    /// `isPlaying` lives on the cursor: the clock stops while paused, so binding
    /// the button to `player` alone left the glyph stale after a pause.
    @EnvironmentObject private var cursor: PlaybackCursor
@Environment(\.palette) private var palette
    @EnvironmentObject private var player: PlayerEngine

    enum Layout {
        static let horizontalPadding: CGFloat = 19
        /// bottombar.js: prev/next/stop canvases are 28pt, the play circle 36pt, gap 13.5pt.
        static let controlSpacing: CGFloat = 13.5
        static let controlWidth: CGFloat = 28
        static let playWidth: CGFloat = 36
        static let elapsedGap: CGFloat = 13.5
        static let sliderGap: CGFloat = 14
        static let trailingGap: CGFloat = 18
        static let rightSpacing: CGFloat = 13.5
        static let volumeWidth: CGFloat = 77
        static let seekTrackHeight: CGFloat = 2.5
        static let seekThumb: CGFloat = 10
        static let volumeTrackHeight: CGFloat = 1.5
        static let volumeThumb: CGFloat = 8
    }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .padding(.trailing, Layout.elapsedGap)

            Text(player.elapsedText)
                .font(Typo.time)
                .foregroundStyle(Theme.text)
                .fixedSize()
                .padding(.trailing, Layout.sliderGap)

            ThinSlider(
                fraction: player.progressFraction,
                fill: palette.sliderFill,
                showGlow: true,
                trackHeight: Layout.seekTrackHeight,
                thumbSize: Layout.seekThumb,
                glowInset: 5,
                label: "播放进度",
                onScrub: { fraction in
                    guard player.duration > 0 else { return }
                    player.seek(to: fraction * player.duration)
                }
            )
            .frame(minWidth: 200, maxWidth: .infinity)

            rightCluster
                .padding(.leading, Layout.trailingGap)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.transportBG)
    }

    // MARK: - Clusters

    private var controls: some View {
        HStack(spacing: Layout.controlSpacing) {
            TransportIconButton(glyph: .previous, size: 19) {
                player.previous()
            }
            .help("上一首")
            .accessibilityLabel("上一首")

            PlayPauseButton(isPlaying: cursor.isPlaying) {
                player.toggle()
            }
            .accessibilityLabel(cursor.isPlaying ? "暂停" : "播放")

            TransportIconButton(glyph: .next, size: 19) {
                player.next()
            }
            .help("下一首")
            .accessibilityLabel("下一首")

            TransportIconButton(glyph: .stop, size: 18) {
                player.stop()
            }
            .help("停止")
            .accessibilityLabel("停止")
        }
    }

    private var rightCluster: some View {
        HStack(spacing: Layout.rightSpacing) {
            Text(player.durationText)
                .font(Typo.time)
                .foregroundStyle(Theme.text)
                .fixedSize()

            TransportIconButton(
                glyph: player.playMode.glyph,
                size: 17,
                color: player.playMode == .sequential ? Theme.text : palette.accent
            ) {
                player.cyclePlayMode()
            }
            .help("\(player.playMode.title) — \(player.playMode.hint)（点一下切换）")
            .accessibilityLabel("播放模式：\(player.playMode.title)")
            .contextMenu {
                ForEach(PlayMode.allCases) { mode in
                    Button {
                        player.playMode = mode
                    } label: {
                        if mode == player.playMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }

            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .frame(width: 20, height: 20)

            ThinSlider(
                fraction: player.volume,
                trackHeight: Layout.volumeTrackHeight,
                thumbSize: Layout.volumeThumb,
                trackColor: Color(white: 0.86),
                glowInset: 4,
                label: "音量",
                onScrub: { fraction in
                    player.volume = fraction
                }
            )
            .frame(width: Layout.volumeWidth)
        }
    }
}

// MARK: - Buttons

/// A plain transport glyph button with a subtle hover brightening.
private struct TransportIconButton: View {
@Environment(\.palette) private var palette
    let glyph: SkinGlyph
    let size: CGFloat
    var width: CGFloat = 28
    var color: Color = Theme.text
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SkinIcon(glyph: glyph, color: color, lineWidth: 1.3)
                .frame(width: size, height: size)
                .frame(width: width, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.85)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The circled play/pause button in the middle of the transport cluster.
private struct PlayPauseButton: View {
@Environment(\.palette) private var palette
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.0)
                    .frame(width: 33, height: 33)

                SkinIcon(glyph: isPlaying ? .pause : .play,
                         color: Theme.text,
                         lineWidth: 1.3)
                    .frame(width: 20, height: 20)
                    .offset(x: isPlaying ? 0 : 1.0)
            }
            .frame(width: TransportBar.Layout.playWidth, height: TransportBar.Layout.playWidth)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.9)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Slider

/// Thin custom slider matching the reference: a 3pt track with a round thumb and a
/// 6pt vertical padding for the hit area. No native `Slider`, no thumb animation.
private struct ThinSlider: View {
@Environment(\.palette) private var palette
    let fraction: Double
    var fill: Color = Color(white: 1).opacity(0.85)
    var showGlow: Bool = false
    var trackHeight: CGFloat = 2.5
    var thumbSize: CGFloat = 10
    /// The reference draws the two rails in different colours: a dark rail behind
    /// the seek bar, a near-white one behind the volume bar.
    var trackColor: Color?
    /// How far the soft halo extends past the thumb (0 disables it).
    var glowInset: CGFloat = 0
    /// Spoken name for VoiceOver; the rail is a bare shape it cannot read.
    var label: String = "进度"
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let progress = CGFloat(min(1, max(0, fraction)))
            let thumbX = width * progress

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor ?? palette.sliderTrack)
                    .frame(width: width, height: trackHeight)

                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: thumbX, height: trackHeight)

                if showGlow, glowInset > 0 {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: thumbSize + glowInset * 2, height: thumbSize + glowInset * 2)
                        .offset(x: thumbX - (thumbSize + glowInset * 2) / 2)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 1)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(width: width, height: trackHeight + 12)
            .contentShape(Rectangle())
            // VoiceOver cannot drag a custom rail, so expose it as an adjustable
            // control that steps by 5%.
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int((progress * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onScrub(min(1, Double(progress) + 0.05))
                case .decrement: onScrub(max(0, Double(progress) - 0.05))
                @unknown default: break
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let value = min(1, max(0, gesture.location.x / width))
                        onScrub(Double(value))
                    }
            )
        }
        .frame(height: trackHeight + 12)
    }
}
