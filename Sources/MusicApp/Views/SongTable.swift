import AppKit
import SwiftUI

// MARK: - Song table (centre column)
//
// Column geometry is sampled from Assets/reference-ui.png (table starts at x = 160pt,
// 729pt wide at the default 1148 x 737 window). The narrow leading columns use the
// Metrics tokens; the four wide text columns keep the reference proportions and shrink
// together on narrow windows so nothing is clipped and the header stays in sync with
// the rows.

struct SongTableColumns {
    var check: CGFloat
    var status: CGFloat
    var title: CGFloat
    var album: CGFloat
    var artist: CGFloat
    var albumArtist: CGFloat
    var genre: CGFloat

    private static let baseTitle: CGFloat = 190
    private static let baseAlbum: CGFloat = 160.5
    private static let baseArtist: CGFloat = 93
    private static let baseAlbumArtist: CGFloat = 98

    static func resolved(for width: CGFloat) -> SongTableColumns {
        let check = Metrics.colCheck
        let status = Metrics.colStatus
        let available = max(0, width - check - status)

        let baseSum = baseTitle + baseAlbum + baseArtist + baseAlbumArtist
        let minGenre = Metrics.colGenreMin
        let scale: CGFloat = available >= baseSum + minGenre
            ? 1
            : max(0, (available - minGenre) / baseSum)

        let title = baseTitle * scale
        let album = baseAlbum * scale
        let artist = baseArtist * scale
        let albumArtist = baseAlbumArtist * scale
        let genre = max(0, available - title - album - artist - albumArtist)

        return SongTableColumns(
            check: check,
            status: status,
            title: title,
            album: album,
            artist: artist,
            albumArtist: albumArtist,
            genre: genre
        )
    }
}

// MARK: - Table

/// The only thing the table needs from the player: three closures. Taking the
/// engine itself would make the table observe it, so every volume drag (which
/// publishes 60 times) would reload all visible rows.
struct SongTableActions {
    let play: (Track, [Track]) -> Void
    let toggle: () -> Void
    let next: () -> Void
}

struct SongTable: View {
@Environment(\.palette) private var palette
    let actions: SongTableActions
    let cursor: PlaybackCursor
    let clock: ProgressClock
    /// One row view per `TableRow`; shared by the lazy stack, the eager render
    /// path and the AppKit table.
    @ViewBuilder
    private func rowViews(_ rows: [TableRow], _ columns: SongTableColumns) -> some View {
        ForEach(rows) { row in
            SongTableRowView(row: row, columns: columns, actions: actions)
                .id(row.id)
        }
    }

    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let rows = store.rows

        GeometryReader { proxy in
            let columns = SongTableColumns.resolved(for: proxy.size.width)

            VStack(spacing: 0) {
                SongTableHeader(columns: columns)
                    .frame(height: Metrics.headerRowHeight)

                if rows.isEmpty {
                    SongTableEmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if RenderMode.isOffscreen {
                    // ImageRenderer cannot lay out a ScrollView, so the render path
                    // draws the rows directly and clips them to the table area.
                    VStack(spacing: 0) { rowViews(rows, columns) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                        .background(palette.windowBG)
                } else if AppKitTableSettings.isEnabled {
                    SongTableAppKit(
                        rows: rows,
                        columns: columns,
                        rowHeight: store.rowHeight,
                        albumHeight: SongTableAlbumRow.height,
                        palette: palette,
                        scrollTarget: store.scrollTarget,
                        derivedRebuilds: store.derivedRebuilds,
                        revealToken: store.revealToken,
                        store: store,
                        actions: actions,
                        cursor: cursor,
                        clock: clock,
                        ticker: store.artworkTicker
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.windowBG)
                    .onAppear {
                        store.prefetchThumbnails(maxPixel: SongTableAlbumRow.thumbPixels)
                    }
                    .onChange(of: store.tracks.count) { _, _ in
                        store.prefetchThumbnails(maxPixel: SongTableAlbumRow.thumbPixels)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) { rowViews(rows, columns) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.windowBG)
                        .onAppear {
                            store.prefetchThumbnails(maxPixel: SongTableAlbumRow.thumbPixels)
                        }
                        .onChange(of: store.tracks.count) { _, _ in
                            store.prefetchThumbnails(maxPixel: SongTableAlbumRow.thumbPixels)
                        }
                        .onChange(of: store.revealToken) { _, _ in
                            guard let target = store.scrollTarget else { return }
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                            store.scrollTarget = nil
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(palette.windowBG)
    }
}

// MARK: - Column header

private struct SongTableHeader: View {
@Environment(\.palette) private var palette
    let columns: SongTableColumns

    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: columns.check)

            headerCell("状态", width: columns.status, column: nil)
            TitleHeaderCell(columns: columns)
            headerCell("专辑", width: columns.album, column: .album)
            headerCell("艺术家", width: columns.artist, column: .artist)
            headerCell("专辑艺术家", width: columns.albumArtist, column: .albumArtist)
            genreCell
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.columnHeader)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func headerCell(_ title: String, width: CGFloat, column: SortColumn?) -> some View {
        let active = column != nil && store.sortColumn == column
        return HStack(spacing: 0) {
            Text(title)
                .font(Typo.header)
                .foregroundStyle(active ? Theme.textStrong : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if active {
                SortIndicator(ascending: store.sortAscending)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
        .contentShape(Rectangle())
        .onTapGesture { if let column { store.toggleSort(column) } }
        .onHover { hovering in
            guard column != nil else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(column.map { "\($0.title)：点一下升序，再点降序，第三次恢复专辑顺序" } ?? "")
    }

    /// "#" and "标题" are two sort targets inside one column.
    private struct TitleHeaderCell: View {
    @Environment(\.palette) private var palette
        let columns: SongTableColumns
        @EnvironmentObject private var store: LibraryStore

        var body: some View {
            HStack(spacing: 0) {
                part("#", column: .trackNumber, width: 18, alignment: .trailing)
                    .padding(.leading, 6)
                part("标题", column: .title, width: 44, alignment: .leading)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                if store.sortColumn == .trackNumber || store.sortColumn == .title {
                    SortIndicator(ascending: store.sortAscending)
                        .padding(.trailing, 4)
                }
            }
            .frame(width: columns.title, alignment: .leading)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { Hairline(vertical: true) }
        }

        private func part(_ text: String, column: SortColumn, width: CGFloat,
                          alignment: Alignment) -> some View {
            let active = store.sortColumn == column
            return Text(text)
                .font(Typo.header)
                .foregroundStyle(active ? Theme.textStrong : Theme.text)
                .lineLimit(1)
                .frame(width: width, alignment: alignment)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleSort(column) }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("\(column.title)：点一下升序，再点降序，第三次恢复专辑顺序")
        }
    }

    private var genreCell: some View {
        let active = store.sortColumn == .genre
        return HStack(spacing: 0) {
            Text("流派")
                .font(Typo.header)
                .foregroundStyle(active ? Theme.textStrong : Theme.text)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleSort(.genre) }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("流派：点一下升序，再点降序，第三次恢复专辑顺序")
            Spacer(minLength: 4)
            if active {
                SortIndicator(ascending: store.sortAscending)
                    .padding(.trailing, 3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(width: columns.genre, alignment: .leading)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
    }
}

/// Small filled triangle drawn next to the sorted column header.
struct SortIndicator: View {
@Environment(\.palette) private var palette
    let ascending: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w: CGFloat = 7, h: CGFloat = 4.5
            let x = (size.width - w) / 2, y = (size.height - h) / 2
            if ascending {
                path.move(to: CGPoint(x: x, y: y + h))
                path.addLine(to: CGPoint(x: x + w, y: y + h))
                path.addLine(to: CGPoint(x: x + w / 2, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + w, y: y))
                path.addLine(to: CGPoint(x: x + w / 2, y: y + h))
            }
            path.closeSubpath()
            context.fill(path, with: .color(Theme.textStrong))
        }
        .frame(width: 9, height: 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Album header row

struct SongTableAlbumRow: View {
@Environment(\.palette) private var palette
    let group: AlbumGroup

    @EnvironmentObject private var store: LibraryStore
    /// Owned by this row: a decoded cover updates one header, not the table.
    @State private var thumb: NSImage?
    /// Which album the cached thumbnail belongs to; states survive cell reuse.
    @State private var loadedAlbumKey: String?

    var body: some View {
        HStack(spacing: 0) {
            cover
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(group.album)
                    .font(Typo.albumTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(group.albumArtist)
                    .font(Typo.albumMeta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                Text(group.yearText)
                    .font(Typo.albumMeta)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(group.countText)
                    .font(Typo.albumMeta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SongTableAlbumRow.height)
        .task(id: group.albumKey) {
            // Drop the previous album's bitmap first: AppKit recycles this host
            // view for a different album, and the state would otherwise show the
            // old cover until the new one finishes decoding.
            if thumb?.size != .zero, loadedAlbumKey != group.albumKey { thumb = nil }
            if let cached = store.cachedThumbnail(for: group.albumKey, maxPixel: Self.thumbPixels) {
                thumb = cached
            } else {
                thumb = await store.thumbnailAsync(for: group.albumKey, maxPixel: Self.thumbPixels)
            }
            loadedAlbumKey = group.albumKey
        }
        .background(palette.albumHeaderBG)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .onTapGesture { store.openGroup(group) }
        .help("在播放列表中查看《\(group.album)》")
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// The reference album header band measures 69.5pt tall: the 62pt cover plus
    /// 4pt of breathing room above and below. The old 105pt block was
    /// 50% taller than the screenshot, so the height is derived from the cover.
    static let height: CGFloat = Metrics.coverThumb + 8

    /// 62pt at 2× with a little headroom for the 1pt border.
    static let thumbPixels: Int = Int(Metrics.coverThumb * 2) + 8

    @ViewBuilder
    private var cover: some View {
        // Thumbnail size, not the 768px file: the cell is 62pt wide, so decoding
        // the full cover only to scale it down 6× was both slower and softer.
        if let image = thumb ?? store.cachedThumbnail(for: group.albumKey, maxPixel: Self.thumbPixels) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Metrics.coverThumb, height: Metrics.coverThumb)
                .clipped()
                .overlay(
                    Rectangle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(palette.controlBG)
                .frame(width: Metrics.coverThumb, height: Metrics.coverThumb)
                .overlay(
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.textDim)
                )
        }
    }
}

// MARK: - Track row

struct SongTableTrackRow: View {
@Environment(\.palette) private var palette
    let track: Track
    let indented: Bool
    let columns: SongTableColumns

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cursor: PlaybackCursor

    /// Actions arrive as closures so the row never observes `PlayerEngine`; that
    /// engine's 30 Hz updates used to rebuild every visible row.
    let onPlay: (Track, [Track]) -> Void
    let onToggle: () -> Void
    let onNext: () -> Void

    @State private var isHovering = false

    private var isSelected: Bool { store.selectedTrackID == track.id }
    private var isChecked: Bool { store.checkedIDs.contains(track.id) }
    private var isPlayingThis: Bool {
        cursor.isPlaying && cursor.trackID == track.id
    }

    var body: some View {
        HStack(spacing: 0) {
            checkCell
            statusCell
            titleCell
            textCell(track.album, width: columns.album)
            textCell(track.artist, width: columns.artist)
            textCell(track.albumArtist, width: columns.albumArtist)
            textCell(track.genre, width: columns.genre)
        }
        .frame(height: store.rowHeight)
        .background(rowBackground)
        .overlay(alignment: .bottom) { RowSeparator(color: palette.separator) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            store.selectedTrackID = track.id
            onPlay(track, store.allVisibleTracks)
        }
        .onTapGesture(count: 1) {
            store.selectedTrackID = track.id
        }
        .contextMenu {
            Button(cursor.trackID == track.id && cursor.isPlaying ? "暂停" : "播放") {
                if cursor.trackID == track.id {
                    onToggle()
                } else {
                    onPlay(track, store.allVisibleTracks)
                }
            }
            Button("下一首") { onNext() }
            Divider()
            Menu("添加到播放列表") {
                ForEach(store.playlists) { playlist in
                    Button(playlist.name) { store.addToPlaylist(track.id, playlistID: playlist.id) }
                }
                if !store.playlists.isEmpty { Divider() }
                Button("新建播放列表") {
                    let playlist = store.addPlaylist()
                    store.addToPlaylist(track.id, playlistID: playlist.id)
                }
            }
            if let playlist = store.activePlaylist,
               playlist.trackIDs.contains(track.id) {
                Button("从「\(playlist.name)」移除") {
                    store.removeFromPlaylist(track.id, playlistID: playlist.id)
                }
            }
        }
    }

    // MARK: Cells

    private var checkCell: some View {
        StatusCheckbox(checked: isChecked)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                store.toggleCheck(track.id)      // must not change the selection
            }
            .padding(.leading, indented ? 22 : max(0, (columns.check - 22) / 2))
            .frame(width: columns.check, alignment: .leading)
    }

    private var statusCell: some View {
        ZStack {
            if isPlayingThis {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(width: columns.status)
    }

    private var titleCell: some View {
        HStack(spacing: 0) {
            Text(numberText)
                .font(Typo.rowNumber)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: showsDisc ? 30 : 18, alignment: .trailing)
                .padding(.trailing, showsDisc ? 2 : 0)
            Text(track.title)
                .font(Typo.row)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: columns.title, alignment: .leading)
    }

    private func textCell(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(Typo.row)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 8)
            .frame(width: width, alignment: .leading)
    }

    /// Multi-disc rips restart numbering on every disc, so a bare "03" read as a
    /// duplicate; prefix the disc there ("3-03"), and keep the single-disc case
    /// exactly as before.
    private var showsDisc: Bool { (track.albumDiscCount ?? 1) > 1 }

    private var numberText: String { track.numberLabel }

    private var rowBackground: Color {
        if isSelected { return palette.selection }
        if isHovering { return palette.controlBG.opacity(0.28) }
        return palette.rowBG
    }
}

// MARK: - Empty state

private struct SongTableEmptyState: View {
@Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text(store.tracks.isEmpty ? "资料库里还没有音乐" : "这个筛选条件下没有曲目")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)

            if store.tracks.isEmpty {
                Text("选一个装着音乐文件的文件夹，扫描一次之后会缓存下来，下次启动直接打开。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button {
                    store.chooseFolder()
                } label: {
                    Text("选择音乐文件夹…（⌘O）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                Button {
                    store.loadDemoLibrary()
                } label: {
                    Text("或者载入示例资料库看界面（没有音频）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            } else {
                Text("点「过滤」右边的 ⨯ 清空搜索词，或换一个视图。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - Row factory

/// Draws one `TableRow`. Shared by every container so the AppKit table and the
/// SwiftUI list cannot drift apart.
struct SongTableRowView: View {
    let row: TableRow
    let columns: SongTableColumns
    let actions: SongTableActions

    var body: some View {
        switch row {
        case .album(let group):
            SongTableAlbumRow(group: group)
        case .track(let track, let indented):
            SongTableTrackRow(
                track: track,
                indented: indented,
                columns: columns,
                onPlay: actions.play,
                onToggle: actions.toggle,
                onNext: actions.next
            )
        }
    }
}


// MARK: - Container switch

/// The AppKit table is the default.
///
/// Measured reason: the SwiftUI `LazyVStack` keeps every row it has scrolled
/// past alive — resident memory grows 319 MB → 403 MB → 493 MB as you move from
/// the top to the middle to the end of a 5,806-track library, and the cost per
/// scroll step grows with it. `NSTableView` recycles its cells, so the same three
/// depths stay at 325 / 328 / 318 MB. `--swiftui-table` keeps the old container
/// around for comparison.
enum AppKitTableSettings {
    static let isEnabled = !CommandLine.arguments.contains("--swiftui-table")
}
