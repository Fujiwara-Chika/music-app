import SwiftUI

/// Left sidebar: "新建播放列表", the three library sections with their track
/// counts, then the user's playlists.
///
/// The reference draws one flat column on `palette.windowBG`: 35pt rows, a full
/// width `palette.selection` band for the selected row and no dividers at all
/// (the filter strip above already draws the column's right edge).
struct SidebarView: View {
@Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore

    @State private var hoveredRow: RowKey?

    private enum RowKey: Hashable {
        case addPlaylist
        case section(LibrarySection)
        case playlist(UUID)
        case mood(MoodChannel)
    }

    private enum L {
        static let rowHeight: CGFloat = 35
        static let leading: CGFloat = 4
        static let iconColumn: CGFloat = 22
        static let titleGap: CGFloat = 6
        static let trailing: CGFloat = 12
        static let sectionIconSize: CGFloat = 11.5
        static let playlistIconSize: CGFloat = 11
        static let plusIconSize: CGFloat = 11
        static let countFont = Font.system(size: 12.5)
    }

    /// `LibrarySection` is not `CaseIterable`; keep the reference order here.
    private static let sections: [LibrarySection] = [.library, .history, .mostPlayed]

    var body: some View {
        VStack(spacing: 0) {
            addPlaylistRow

            ForEach(Self.sections, id: \.self) { section in
                sectionRow(section)
            }

            if store.viewMode == .mood, store.selectedSection == .library {
                moodChannels
            }

            ForEach(store.playlists) { playlist in
                playlistRow(playlist)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.windowBG)
    }

    // MARK: - Rows

    private var addPlaylistRow: some View {
        row(
            key: .addPlaylist,
            symbol: "plus",
            symbolSize: L.plusIconSize,
            title: "新建播放列表",
            count: nil,
            isSelected: false,
            action: { store.addPlaylist() }
        )
    }

    private func sectionRow(_ section: LibrarySection) -> some View {
        row(
            key: .section(section),
            symbol: section.systemImage,
            symbolSize: L.sectionIconSize,
            title: section.title,
            count: store.count(for: section),
            isSelected: isSelected(section),
            action: {
                store.selectedPlaylistID = nil
                store.selectedSection = section
            }
        )
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        row(
            key: .playlist(playlist.id),
            symbol: "music.note.list",
            symbolSize: L.playlistIconSize,
            title: playlist.name,
            count: playlist.trackIDs.count,
            isSelected: store.selectedPlaylistID == playlist.id,
            action: {
                store.selectedPlaylistID = playlist.id
                store.selectedSection = .library
            }
        )
        .contextMenu {
            Button("删除播放列表", role: .destructive) { store.removePlaylist(playlist.id) }
        }
    }

    /// The eight mood channels, with counts and a progress line while the
    /// analyser is still working through the library.
    private var moodChannels: some View {
        VStack(spacing: 0) {
            moodHeader("心情频道")
            ForEach(MoodChannel.allCases) { channel in
                moodRow(channel)
            }
            if store.moodTotal > 0 {
                moodHeader(analysisProgress, size: 10.5, weight: .regular)
            }
        }
    }

    private var analysisProgress: String {
        "正在分析心情 \(store.moodDone)/\(store.moodTotal)"
    }

    private func moodHeader(_ title: String,
                            size: CGFloat = 10.5,
                            weight: Font.Weight = .semibold) -> some View {
        let inset: CGFloat = L.leading + L.iconColumn + L.titleGap
        return Text(title)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, inset)
            .padding(.top, weight == .semibold ? 10 : 6)
            .padding(.bottom, weight == .semibold ? 4 : 0)
    }

    private func moodRow(_ channel: MoodChannel) -> some View {
        row(
            key: .mood(channel),
            symbol: channel.systemImage,
            symbolSize: L.sectionIconSize,
            title: channel.title,
            count: store.moodCount(channel),
            isSelected: store.selectedMoodChannel == channel,
            action: { toggleMoodChannel(channel) }
        )
    }

    private func toggleMoodChannel(_ channel: MoodChannel) {
        store.selectedPlaylistID = nil
        store.selectedSection = .library
        store.viewMode = .mood
        store.selectedMoodChannel = store.selectedMoodChannel == channel ? nil : channel
    }

    // MARK: - Row scaffold

    private func row(
        key: RowKey,
        symbol: String,
        symbolSize: CGFloat,
        title: String,
        count: Int?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRow == key
        let foreground: Color = isSelected ? Theme.textStrong : Theme.text
        let secondary: Color = isSelected ? Theme.textStrong : Theme.textSecondary

        return Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(secondary)
                    .frame(width: L.iconColumn, height: L.rowHeight)
                    .padding(.leading, L.leading)

                Text(title)
                    .font(Typo.sidebar)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, L.titleGap)

                Spacer(minLength: 4)

                if let count {
                    Text(verbatim: "\(count)")
                        .font(L.countFont)
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                        .padding(.trailing, L.trailing)
                }
            }
            .frame(height: L.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    palette.selection
                } else if isHovered {
                    palette.controlBG.opacity(0.35)
                } else {
                    Color.clear
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            if hovering {
                hoveredRow = key
            } else if hoveredRow == key {
                hoveredRow = nil
            }
        }
    }

    // MARK: - Selection

    /// A library section is highlighted only while no playlist is selected
    /// (`addPlaylist()` sets both, so the media library must not light up too).
    private func isSelected(_ section: LibrarySection) -> Bool {
        store.selectedPlaylistID == nil && store.selectedSection == section
    }
}
