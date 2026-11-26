import SwiftUI

/// The mood map: every analysed track as a dot on a tempo × valence plane, with
/// the eight channels labelled where their anchors sit. Clicking a label selects
/// the channel, so the map doubles as the channel picker.
struct MoodMapView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore

    static let height: CGFloat = 108

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 18
            let plot = CGRect(x: inset, y: 12,
                              width: max(size.width - inset * 2, 1),
                              height: max(size.height - 30, 1))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(&context, plot: plot)
                }
                ForEach(MoodChannel.allCases) { channel in
                    channelLabel(channel, plot: plot)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(height: Self.height)
        .background(palette.columnHeader.opacity(0.6))
        .overlay(alignment: .bottom) { Divider().overlay(palette.separator) }
    }

    private func position(_ features: MoodFeatures, in plot: CGRect) -> CGPoint {
        // Valence runs -1…+1 bottom to top; tempo runs left to right.
        let x = plot.minX + plot.width * features.tempoPosition
        let y = plot.maxY - plot.height * (features.valencePosition + 1) / 2
        return CGPoint(x: x, y: y)
    }

    private func draw(_ context: inout GraphicsContext, plot: CGRect) {
        let selected = store.selectedMoodChannel
        var faintPaths: [MoodChannel: Path] = [:]
        var highlightPaths: [MoodChannel: Path] = [:]

        for track in store.tracks {
            guard let features = track.mood else { continue }
            let point = position(features, in: plot)
            let rect = CGRect(x: point.x - 1, y: point.y - 1, width: 2.2, height: 2.2)
            let channel = MoodChannel.classify(features)
            if selected == channel {
                var path = highlightPaths[channel] ?? Path()
                path.addEllipse(in: rect)
                highlightPaths[channel] = path
            } else {
                var path = faintPaths[channel] ?? Path()
                path.addEllipse(in: rect)
                faintPaths[channel] = path
            }
        }

        // Colour carries the channel: the cloud reads as eight overlapping zones
        // instead of one grey lawn.
        for (channel, path) in faintPaths {
            context.fill(path, with: .color(color(for: channel).opacity(selected == nil ? 0.30 : 0.10)))
        }
        for (channel, path) in highlightPaths {
            context.fill(path, with: .color(color(for: channel).opacity(0.95)))
        }
        for channel in MoodChannel.allCases where channel == selected {
            let point = CGPoint(x: plot.minX + plot.width * channel.anchor.x,
                                y: plot.maxY - plot.height * (channel.anchor.y + 1) / 2)
            let ring = Path(ellipseIn: CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52))
            context.stroke(ring, with: .color(color(for: channel).opacity(0.55)), lineWidth: 0.75)
        }

        // Axis hint: the floor of the plane.
        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(baseline, with: .color(Theme.textDim.opacity(0.35)), lineWidth: 0.5)
    }

    private func channelLabel(_ channel: MoodChannel, plot: CGRect) -> some View {
        let x = plot.minX + plot.width * channel.anchor.x
        let y = plot.maxY - plot.height * (channel.anchor.y + 1) / 2
        let isSelected = store.selectedMoodChannel == channel
        return Text(verbatim: channel.title)
            .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? color(for: channel) : Theme.textDim)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isSelected ? color(for: channel).opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectedPlaylistID = nil
                store.selectedSection = .library
                store.viewMode = .mood
                store.selectedMoodChannel = isSelected ? nil : channel
            }
            .help("\(channel.title) — 点一下只看这个频道")
            .offset(x: x - 16, y: y - 8)
    }

    /// A stable hue per channel, built from the palette's accent so the map still
    /// follows the playing cover.
    private func color(for channel: MoodChannel) -> Color {
        switch channel {
        case .morning:   return Theme.accent.opacity(0.9)
        case .daytime:   return .yellow
        case .evening:   return .orange
        case .night:     return .indigo
        case .workout:   return .green
        case .relax:     return .teal
        case .emotional: return .pink
        case .upbeat:    return .mint
        }
    }
}
