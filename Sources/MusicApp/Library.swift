import SwiftUI
import AppKit
import AVFoundation

// MARK: - Rows shown by the main table

enum TableRow: Identifiable {
    case album(AlbumGroup)
    case track(Track, indented: Bool)

    var id: String {
        switch self {
        case .album(let g):         return "album:" + g.id
        case .track(let t, _):      return "track:" + t.id.uuidString
        }
    }

    var track: Track? {
        if case .track(let t, _) = self { return t }
        return nil
    }

    var group: AlbumGroup? {
        if case .album(let g) = self { return g }
        return nil
    }
}

// MARK: - Store

@MainActor
final class LibraryStore: ObservableObject {

    // Content
    @Published var tracks: [Track] = [] { didSet { contentVersion &+= 1 } }
    @Published var playlists: [Playlist] = []
    @Published var selectedPlaylistID: UUID? = nil
    /// Bumped when a playlist's membership changes, so the memoised rows rebuild.
    @Published private(set) var playlistRevision = 0
    @Published var sourceName: String = "示例资料库"
    @Published var isDemoLibrary: Bool = true
    @Published var isScanning: Bool = false

    // UI state
    @Published var filterText: String = ""
    @Published var selectedSection: LibrarySection = .library
    @Published var selectedTrackID: UUID? = nil
    @Published var checkedIDs: Set<UUID> = []
    /// Active column sort. `nil` keeps the grouped, album-ordered layout; any
    /// value flattens the table into one sorted list.
    @Published var sortColumn: SortColumn? = nil
    @Published var sortAscending = true

    /// Which of the five view tabs in the top bar is active; it decides how the
    /// table groups rows (album / artist / genre / play statistics).
    @Published var viewMode: ViewMode = .playlist
    /// Bumped whenever a cover image is replaced, so views showing artwork redraw.
    @Published private(set) var artworkRevision = 0
    private var artworkUpgrades: Set<String> = []
    private var artworkUpgradePassStarted = false
    @Published var isCompactRows = false
    /// Row id (`track:<uuid>`) the table should scroll into view. Row ids are
    /// strings because album headers are rows too.
    @Published var scrollTarget: String?
    /// When on, playback that moves to another track scrolls the table to it
    /// (auto-advance at the end of a song, next/previous, the top-bar button).
    @Published var followsPlayback = true

    var rowHeight: CGFloat { isCompactRows ? Metrics.compactRowHeight : Metrics.rowHeight }

    private var contentVersion = 0
    /// Incremented on every scan; a pass whose generation no longer matches has
    /// been superseded and must not publish.
    private var scanGeneration = 0
    /// Covers are decoded bitmaps (~2.4 MB each at 768²), so the cache is capped
    /// by cost: browsing a large library must not grow memory without bound.
    private let artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 240
        return cache
    }()
    private var artworkMissing: Set<String> = []
    private var artworkLoading: Set<String> = []
    /// Last fully-published library. `tracks` itself is published in slices while
    /// a scan runs, so a rescan must not take its "previous" state from there.
    private var lastCompleteTracks: [Track] = []
    private var saveTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let folderKey = "library.folder.path"
    /// Stable `path → id` map, independent of what the last scan happened to
    /// see. `lastCompleteTracks` cannot serve this purpose: an empty scan wipes
    /// it, which is exactly when playlist membership needs the ids back.
    private var trackIDsByPath: [String: UUID] = [:]

    /// The part of the index worth writing to disk: ids for files the current
    /// scan could not see. Everything else is already in `tracks`, and copying it
    /// into the snapshot just made the file 26% bigger (899 KB of duplicate
    /// paths) for no benefit — `apply` re-seeds from `tracks` anyway.
    private var orphanTrackIDs: [String: UUID]? {
        let live = Set(tracks.compactMap { $0.url?.path })
        let orphans = trackIDsByPath.filter { !live.contains($0.key) }
        // `nil` rather than `{}`: the common case writes nothing at all.
        return orphans.isEmpty ? nil : orphans
    }

    /// The folder the *current* library came from. `defaults` cannot answer this:
    /// `chooseFolder` writes the new path before the scan starts, so during a
    /// folder switch it already points at the new library.
    private var activeFolderPath: String?

    /// The library cache's only writer. Injected so the self-test and the
    /// offscreen renderer can point at a scratch directory instead of the
    /// user's real library (play counts live in that snapshot).
    let cache: SnapshotWriter

    /// `autoLoad: false` keeps the store empty: tools (the self-test, the
    /// offscreen renderer) build their own library and must not kick off a scan
    /// of whatever folder the real app happens to have configured.
    init(autoLoad: Bool = true, cacheOnly: Bool = false, cache: SnapshotWriter = SnapshotWriter()) {
        self.cache = cache
        guard autoLoad else { return }
        // A cold start shows an empty library with an "import" call to action.
        // The demo albums exist only to match the reference screenshot, and they
        // have no audio behind them, so they must never be what a fresh install
        // opens with — the menu item 「载入示例资料库」 loads them on request.
        guard let path = defaults.string(forKey: folderKey) else { return }
        // Opening the window must not walk 5,800 files. The snapshot written by
        // the last scan is used until the user asks for a rescan (⌘R).
        if let snapshot = cache.load(), snapshot.folderPath == path {
            // An empty snapshot is a real state (the folder was emptied), and its
            // playlists plus the id index have to come back with it.
            apply(snapshot)
            if snapshot.tracks.isEmpty, !cacheOnly,
               FileManager.default.fileExists(atPath: path) {
                Task { await self.scan(folder: URL(fileURLWithPath: path)) }
            }
            return
        }
        // Tools that only want to *read* the library (the offscreen renderer)
        // must never start a scan, which would fight over the cache files.
        guard !cacheOnly else { return }
        if FileManager.default.fileExists(atPath: path) {
            Task { await self.scan(folder: URL(fileURLWithPath: path)) }
        }
    }

    /// Test-only: adopt a snapshot as if the app had just launched with it.
    func adoptSnapshotForTesting(_ snapshot: LibrarySnapshot) {
        apply(snapshot)
    }

    /// Replace the visible library with a cached snapshot.
    private func apply(_ snapshot: LibrarySnapshot) {
        NSLog("音乐: library cache hit – %d tracks (%@)", snapshot.tracks.count, snapshot.folderPath)
        activeFolderPath = snapshot.folderPath
        tracks = snapshot.tracks
        lastCompleteTracks = snapshot.tracks
        playlists = snapshot.playlists ?? []
        // Snapshots written before the index existed still have every track, so
        // seed the index from them — otherwise the first empty scan of an
        // existing library would still lose playlist membership.
        trackIDsByPath = snapshot.trackIDsByPath ?? [:]
        for track in snapshot.tracks {
            if let path = track.url?.path { trackIDsByPath[path] = track.id }
        }
        artworkCache.removeAllObjects()
        loadBundledArtwork()
        isDemoLibrary = false
        sourceName = URL(fileURLWithPath: snapshot.folderPath).lastPathComponent
        selectedSection = .library
        selectedTrackID = groups.first?.tracks.first?.id ?? snapshot.tracks.first?.id
    }

    /// Force a fresh walk of the imported folder and rewrite the snapshot.
    func rescan() {
        guard let path = defaults.string(forKey: folderKey) else { return }
        Task { await self.scan(folder: URL(fileURLWithPath: path)) }
    }

    // MARK: - Derived content
    //
    // `rows` is read from `SongTable.body`, so anything that publishes on this
    // object (a click, a play count, the palette) would otherwise re-sort the
    // whole library. Everything below is memoised on the inputs that matter and
    // only rebuilt when one of them actually changes.

    private struct DerivedKey: Equatable {
        var content: Int
        var filter: String
        var mode: ViewMode
        var section: LibrarySection
        var column: SortColumn?
        var ascending: Bool
        var playlist: UUID?
        var playlistRevision: Int
    }

    private var derivedKey: DerivedKey?
    private var derivedFiltered: [Track] = []
    private var derivedGroups: [AlbumGroup] = []
    private var derivedRows: [TableRow] = []
    private var derivedAllTracks: [Track] = []
    /// Number of times the derived state had to be rebuilt; asserted by the self-test.
    private(set) var derivedRebuilds = 0

    private var currentKey: DerivedKey {
        DerivedKey(content: contentVersion, filter: filterText, mode: viewMode,
                   section: selectedSection, column: sortColumn,
                   ascending: sortAscending,
                   playlist: selectedPlaylistID, playlistRevision: playlistRevision)
    }

    private func ensureDerived() {
        let key = currentKey
        if key == derivedKey { return }
        derivedKey = key
        derivedRebuilds &+= 1


        let filtered = computeFiltered()
        derivedFiltered = filtered
        let groups = computeGroups(from: filtered)
        derivedGroups = groups
        derivedRows = computeRows(filtered: filtered, groups: groups)
        derivedAllTracks = derivedRows.compactMap(\.track)
    }

    var filteredTracks: [Track] {
        ensureDerived()
        return derivedFiltered
    }

    /// Groups for the current filter and view mode.
    ///
    /// The playlist/album views group by album (the reference's layout), the
    /// artist and genre views reuse the same header row with a different key, so
    /// the table keeps one code path.
    var groups: [AlbumGroup] {
        ensureDerived()
        return derivedGroups
    }

    /// Rows for the table: album headers + indented tracks (library), or a flat list.
    var rows: [TableRow] {
        ensureDerived()
        return derivedRows
    }

    var allVisibleTracks: [Track] {
        ensureDerived()
        return derivedAllTracks
    }

    private func computeFiltered() -> [Track] {
        var pool = tracks
        // A selected playlist is a scope, not a decoration: it narrows the pool
        // that the text filter and the view mode then work on.
        if let playlistID = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            let members = Set(playlist.trackIDs)
            pool = pool.filter { members.contains($0.id) }
        }
        let q = filterText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return pool }
        return pool.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.album.localizedCaseInsensitiveContains(q) ||
            $0.artist.localizedCaseInsensitiveContains(q) ||
            $0.albumArtist.localizedCaseInsensitiveContains(q) ||
            $0.genre.localizedCaseInsensitiveContains(q)
        }
    }

    private func computeGroups(from filtered: [Track]) -> [AlbumGroup] {
        var buckets: [String: [Track]] = [:]
        var order: [String] = []

        func key(for track: Track) -> String {
            switch viewMode {
            case .playlist, .albums, .stats: return track.albumKey
            case .artists: return track.artist.isEmpty ? "未知艺术家" : track.artist
            case .genres:  return track.genre.isEmpty ? "未分类" : track.genre
            }
        }

        for t in filtered {
            let k = key(for: t)
            if buckets[k] == nil { buckets[k] = []; order.append(k) }
            buckets[k]?.append(t)
        }

        var result: [AlbumGroup] = []
        for k in order {
            guard let items = buckets[k], let first = items.first else { continue }
            // Inside a group the album always comes first: in the artist and
            // genre views one group spans many albums, and ordering those songs by
            // disc/track alone stacks every album's "01" at the top.
            let songs = items.sorted { a, b in
                let album = a.album.localizedStandardCompare(b.album)
                if album != .orderedSame { return album == .orderedAscending }
                if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
                if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            let albumArtist = first.albumArtist.isEmpty ? first.artist : first.albumArtist
            switch viewMode {
            case .artists, .genres:
                result.append(AlbumGroup(
                    id: "\(viewMode.rawValue):\(k)",
                    albumKey: first.albumKey,      // borrow the first album's cover
                    album: k,
                    albumArtist: "",
                    artist: "",
                    year: 0,
                    trackCount: songs.count,
                    tracks: songs
                ))
            default:
                result.append(AlbumGroup(
                    albumKey: k,
                    album: first.album,
                    albumArtist: albumArtist,
                    artist: first.artist,
                    year: first.year,
                    trackCount: songs.count,
                    tracks: songs
                ))
            }
        }

        result.sort { a, b in
            switch viewMode {
            case .playlist:
                // Library order: artist first, then the album title. Sorting by
                // year (as the reference screenshot does for one artist) puts
                // every 2015 album of every artist ahead of everything else,
                // which is not a music library order.
                let r = a.albumArtist.localizedStandardCompare(b.albumArtist)
                if r != .orderedSame { return r == .orderedAscending }
                let name = a.album.localizedStandardCompare(b.album)
                if name != .orderedSame { return name == .orderedAscending }
                if a.year != b.year { return a.year < b.year }
                return (a.tracks.first?.trackNumber ?? 0) < (b.tracks.first?.trackNumber ?? 0)
            case .albums, .artists, .genres, .stats:
                return a.album.localizedStandardCompare(b.album) == .orderedAscending
            }
        }
        return result
    }

    private func computeRows(filtered: [Track], groups: [AlbumGroup]) -> [TableRow] {
        // A column sort always wins: the grouped layout only makes sense while
        // the table is ordered by album.
        if let column = sortColumn, selectedSection == .library, viewMode != .albums {
            return sortedTracks(by: column, from: filtered).map { .track($0, indented: false) }
        }
        switch selectedSection {
        case .library where viewMode == .stats:
            let items = filtered.sorted { a, b in
                if a.playCount != b.playCount { return a.playCount > b.playCount }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            return items.map { .track($0, indented: false) }

        case .library:
            var out: [TableRow] = []
            out.reserveCapacity(groups.count + filtered.count)
            for g in groups {
                out.append(.album(g))
                // 专辑视图只列专辑头；点一行就跳到播放列表并过滤到那张专辑。
                if viewMode != .albums {
                    for t in g.tracks { out.append(.track(t, indented: true)) }
                }
            }
            return out

        case .history:
            let items = filtered
                .filter { $0.lastPlayed != nil }
                .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return items.map { .track($0, indented: false) }

        case .mostPlayed:
            let items = filtered
                .filter { $0.playCount > 0 }
                .sorted { $0.playCount > $1.playCount }
            return items.map { .track($0, indented: false) }
        }
    }

    // MARK: - Column sorting

    /// Clicking a header cycles ascending → descending → back to the album order.
    func toggleSort(_ column: SortColumn) {
        // The album view lists headers only, so a column sort has nothing to
        // order there: drop back to the playlist view, which does.
        if viewMode == .albums { viewMode = .playlist }
        if sortColumn == column {
            if sortAscending {
                sortAscending = false
            } else {
                sortColumn = nil
                sortAscending = true
            }
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    /// Album artist when present, otherwise the performing artist: the value the
    /// album header shows, and the one the library order sorts on.
    static func libraryArtist(_ track: Track) -> String {
        track.albumArtist.isEmpty ? track.artist : track.albumArtist
    }

    func sortedTracks(by column: SortColumn) -> [Track] {
        sortedTracks(by: column, from: filteredTracks)
    }

    func sortedTracks(by column: SortColumn, from items: [Track]) -> [Track] {
        let ascending = sortAscending

        func compare(_ a: Track, _ b: Track) -> Bool {
            switch column {
            case .trackNumber:
                // The natural library order: artist, album, disc, track.
                let artist = Self.libraryArtist(a).localizedStandardCompare(Self.libraryArtist(b))
                if artist != .orderedSame { return artist == .orderedAscending }
                let album = a.album.localizedStandardCompare(b.album)
                if album != .orderedSame { return album == .orderedAscending }
                if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
                if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .title:
                let r = a.title.localizedStandardCompare(b.title)
                if r != .orderedSame { return r == .orderedAscending }
                return a.artist.localizedStandardCompare(b.artist) == .orderedAscending
            case .album:
                let r = a.album.localizedStandardCompare(b.album)
                if r != .orderedSame { return r == .orderedAscending }
                if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
                return a.trackNumber < b.trackNumber
            case .artist:
                let r = a.artist.localizedStandardCompare(b.artist)
                if r != .orderedSame { return r == .orderedAscending }
                return a.album.localizedStandardCompare(b.album) == .orderedAscending
            case .albumArtist:
                let r = a.albumArtist.localizedStandardCompare(b.albumArtist)
                if r != .orderedSame { return r == .orderedAscending }
                return a.album.localizedStandardCompare(b.album) == .orderedAscending
            case .genre:
                let r = a.genre.localizedStandardCompare(b.genre)
                if r != .orderedSame { return r == .orderedAscending }
                return a.artist.localizedStandardCompare(b.artist) == .orderedAscending
            }
        }

        // Empty values always sink to the bottom, in both directions: a blank
        // genre or album artist is "unknown", not the smallest possible value.
        func hasValue(_ t: Track) -> Bool {
            switch column {
            case .trackNumber: return t.trackNumber > 0
            case .title:       return !t.title.isEmpty
            case .album:       return !t.album.isEmpty
            case .artist:      return !t.artist.isEmpty
            case .albumArtist: return !t.albumArtist.isEmpty
            case .genre:       return !t.genre.isEmpty
            }
        }

        let withValue = items.filter { hasValue($0) }
        let without = items.filter { !hasValue($0) }.sorted { a, b in
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let forward = withValue.sorted(by: compare) + without
        return ascending ? forward : withValue.sorted(by: compare).reversed() + without
    }

    func count(for section: LibrarySection) -> Int {
        switch section {
        case .library:    return tracks.count
        case .history:    return tracks.filter { $0.lastPlayed != nil }.count
        case .mostPlayed: return tracks.filter { $0.playCount > 0 }.count
        }
    }

    var selectedTrack: Track? {
        guard let id = selectedTrackID else { return nil }
        return tracks.first { $0.id == id }
    }


    /// Non-blocking lookup used by the scrolling UI.
    ///
    /// The first call for a cover returns nil and kicks off a background decode;
    /// the bitmap arrives through `artworkRevision`. `artworkMissing` is a real
    /// negative cache (the album has no cover at all) and `artworkLoading` keeps
    /// repeated `body` evaluations from stacking up decodes for the same album.
    func artwork(for albumKey: String) -> NSImage? {
        if let image = artworkCache.object(forKey: albumKey as NSString) {
            return image
        }
        guard !artworkMissing.contains(albumKey), !artworkLoading.contains(albumKey) else { return nil }
        artworkLoading.insert(albumKey)
        Task {
            let image = await decodeArtwork(for: albumKey)
            artworkLoading.remove(albumKey)
            if let image {
                store(image, for: albumKey)
                artworkRevision &+= 1
            } else if isDemoLibrary {
                artworkMissing.insert(albumKey)
            } else {
                // Not in the cache file: re-extract it from the audio file, and
                // only mark it missing if that fails too.
                refreshArtwork(albumKey, ifSmallerThan: .infinity, markingMissingOnFailure: true)
            }
        }
        return nil
    }

    /// Blocking lookup for the offscreen renderer and tests, where there is no
    /// run loop for the async decode to land on.
    func artworkNow(for albumKey: String) -> NSImage? {
        if let image = artworkCache.object(forKey: albumKey as NSString) { return image }
        guard !artworkMissing.contains(albumKey) else { return nil }
        guard let image = cache.readArtwork(for: albumKey) else { return nil }
        store(image, for: albumKey)
        return image
    }

    /// Puts a decoded cover in the cache, charging its bitmap size.
    private func store(_ image: NSImage, for albumKey: String) {
        artworkMissing.remove(albumKey)
        artworkCount += 1
        let pixels = Int(image.size.width * image.size.height)
        artworkCache.setObject(image, forKey: albumKey as NSString, cost: max(pixels * 4, 1))
    }

    /// Decodes one cached cover off the main actor.
    ///
    /// `NSImage` is not `Sendable`; the box is the usual escape hatch for a
    /// fully-decoded, immutable bitmap handed back to the main actor.
    private struct ArtworkBox: @unchecked Sendable {
        let image: NSImage?
    }

    private func decodeArtwork(for albumKey: String) async -> NSImage? {
        let writer = cache
        return await Task.detached(priority: .userInitiated) {
            ArtworkBox(image: writer.readArtwork(for: albumKey))
        }.value.image
    }

    /// Covers cached by earlier builds were capped at 512px, which is exactly the
    /// panel's 2× size — no headroom, so they read as slightly soft. When such a
    /// cover is requested and its audio file is still around, re-extract the
    /// embedded art in the background and swap it in. `ifSmallerThan` of
    /// `.infinity` means "rebuild unconditionally".
    private func refreshArtwork(_ albumKey: String,
                                ifSmallerThan threshold: CGFloat,
                                markingMissingOnFailure: Bool = false) {
        let current = artworkCache.object(forKey: albumKey as NSString)?.size.width ?? 0
        guard current < threshold,
              !artworkUpgrades.contains(albumKey),
              let url = tracks.first(where: { $0.albumKey == albumKey })?.url else { return }
        artworkUpgrades.insert(albumKey)
        Task {
            // `avatarData(from:)` is a plain async function, so the file read and
            // the WebP/PNG/JPEG decode happen off the main actor; only the
            // dictionary swap comes back here.
            let data = await LibraryStore.embeddedArtworkData(from: url)
            guard let data, let fresh = NSImage(data: data), fresh.size.width > current else {
                artworkUpgrades.remove(albumKey)
                if markingMissingOnFailure, data == nil { artworkMissing.insert(albumKey) }
                return
            }
            cache.writeArtwork(fresh, for: albumKey)
            store(fresh, for: albumKey)
            artworkRevision &+= 1
        }
    }

    /// One background pass that brings every cached cover up to the current
    /// resolution, so browsing does not have to be the trigger. Runs once per
    /// launch, in small chunks, and does nothing for covers already large enough.
    func startArtworkUpgradePass() {
        guard !artworkUpgradePassStarted, !isDemoLibrary, !tracks.isEmpty else { return }
        artworkUpgradePassStarted = true
        let urlByKey = Dictionary(tracks.map { ($0.albumKey, $0.url) }, uniquingKeysWith: { first, _ in first })
        let threshold = Int(SnapshotWriter.maxArtworkSide * 0.9)
        Task {
            var done = 0
            for (albumKey, url) in urlByKey {
                if let side = cache.artworkPixelSide(for: albumKey), side >= threshold { continue }
                guard let url, let data = await LibraryStore.embeddedArtworkData(from: url),
                      let fresh = NSImage(data: data), fresh.size.width > 1 else { continue }
                cache.writeArtwork(fresh, for: albumKey)
                store(fresh, for: albumKey)
                done += 1
                if done % 8 == 0 {
                    artworkRevision &+= 1
                    await Task.yield()
                }
            }
            if done > 0 {
                artworkRevision &+= 1
                NSLog("音乐: upgraded %d cached covers", done)
            }
        }
    }

    /// Reads the artwork bytes embedded in one audio file.
    static func embeddedArtworkData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    /// Header click: show that album / artist / genre in the playlist view.
    func openGroup(_ group: AlbumGroup) {
        // Every view mode drills in the same way: filter to the group's name and
        // show it in the playlist layout.
        filterText = group.album
        viewMode = .playlist
        selectedSection = .library
        selectedTrackID = group.tracks.first?.id
        scrollTarget = nil
    }

    /// Number of albums with artwork (used by the headless self test).
    var artworkCount: Int = 0

    func track(id: UUID) -> Track? { tracks.first { $0.id == id } }

    /// Scrolls the table to a row that is actually part of the current rows —
    /// a track played from another view (or a stale filter) simply stays put.
    func reveal(trackID: UUID, force: Bool = false) {
        let wanted = "track:" + trackID.uuidString
        guard force || followsPlayback, rows.contains(where: { $0.id == wanted }) else { return }
        scrollTarget = wanted
    }

    // MARK: - Mutations

    func toggleCheck(_ id: UUID) {
        if checkedIDs.contains(id) { checkedIDs.remove(id) } else { checkedIDs.insert(id) }
    }

    func notePlay(_ track: Track) {
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[idx].playCount += 1
        tracks[idx].lastPlayed = Date()
        // Keep the "previous library" copy in step: a rescan merges statistics
        // from it, so a stale copy would silently undo this play.
        if let mirror = lastCompleteTracks.firstIndex(where: { $0.id == track.id }) {
            lastCompleteTracks[mirror] = tracks[idx]
        }
        scheduleSave()
    }

    func setRating(_ rating: Int, for id: UUID) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[idx].rating = rating
        if let mirror = lastCompleteTracks.firstIndex(where: { $0.id == id }) {
            lastCompleteTracks[mirror] = tracks[idx]
        }
        scheduleSave()
    }

    /// Writes the snapshot right now. Used when the app is about to quit: the
    /// debounced write below would otherwise be dropped, losing a playlist or a
    /// rating made in the last couple of seconds.
    func flushSnapshot() {
        // While a scan runs, `tracks` holds only the batches published so far;
        // writing that would leave the next launch with a truncated library.
        guard !isDemoLibrary, !isScanning else { return }
        guard let path = activeFolderPath ?? defaults.string(forKey: folderKey) else { return }
        saveTask?.cancel()
        saveTask = nil
        cache.flush(LibrarySnapshot(folderPath: path, savedAt: Date(),
                                    tracks: tracks, playlists: playlists,
                                    trackIDsByPath: orphanTrackIDs))
    }

    /// Ratings and play counts change row by row while browsing; writing a 3MB
    /// snapshot after every click would thrash the disk, so writes are debounced.
    private func scheduleSave() {
        guard !isDemoLibrary, !isScanning else { return }
        guard let path = activeFolderPath ?? defaults.string(forKey: folderKey) else { return }
        saveTask?.cancel()
        let snapshot = LibrarySnapshot(folderPath: path, savedAt: Date(),
                                       tracks: tracks, playlists: playlists,
                                       trackIDsByPath: orphanTrackIDs)
        saveTask = Task { [snapshot] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            cache.write(snapshot)
        }
    }

    @discardableResult
    func addPlaylist() -> Playlist {
        let p = Playlist(name: "新建播放列表 \(playlists.count + 1)")
        playlists.append(p)
        playlistRevision &+= 1
        selectedPlaylistID = p.id
        selectedSection = .library
        scheduleSave()
        return p
    }

    func addToPlaylist(_ trackID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].trackIDs.contains(trackID) else { return }
        playlists[index].trackIDs.append(trackID)
        playlistRevision &+= 1
        scheduleSave()
    }

    func removeFromPlaylist(_ trackID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        playlistRevision &+= 1
        scheduleSave()
    }

    func removePlaylist(_ playlistID: UUID) {
        playlists.removeAll { $0.id == playlistID }
        if selectedPlaylistID == playlistID { selectedPlaylistID = nil }
        playlistRevision &+= 1
        scheduleSave()
    }

    /// Playlist currently shown as the table's scope, if any.
    var activePlaylist: Playlist? {
        selectedPlaylistID.flatMap { id in playlists.first { $0.id == id } }
    }

    // MARK: - Artwork loading

    private func loadBundledArtwork() {
        let map: [String: String] = [
            "DAWN\u{1}Aimer": "cover-dawn",
            "Live at anywhere\u{1}Aimer": "cover-live",
            "daydream\u{1}Aimer": "cover-daydream"
        ]
        for (key, name) in map {
            if let url = AppResources.bundle.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                store(img, for: key)
            }
        }
    }

    // MARK: - Import

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描"
        panel.message = "选择一个音乐文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: folderKey)
            Task { await self.scan(folder: url) }
        }
    }

    func clearImportedLibrary() {
        defaults.removeObject(forKey: folderKey)
        // A debounced save from a moment ago would otherwise write the old
        // library back after the files are gone.
        saveTask?.cancel()
        saveTask = nil
        activeFolderPath = nil
        trackIDsByPath = [:]
        cache.clear()
        // Cold start is an empty library with an import call to action; loading
        // the demo set here would contradict that.
        scanGeneration &+= 1
        tracks = []
        lastCompleteTracks = []
        playlists = []
        playlistRevision &+= 1
        selectedPlaylistID = nil
        artworkCache.removeAllObjects()
        artworkMissing.removeAll()
        artworkLoading.removeAll()
        artworkUpgrades.removeAll()
        artworkUpgradePassStarted = false
        filterText = ""
        checkedIDs.removeAll()
        selectedTrackID = nil
        isDemoLibrary = false
        sourceName = "媒体库"
    }

    /// Scan a folder for audio files and read their metadata.
    ///
    /// Files are published in batches while the scan runs: a 4000-track folder
    /// takes a few seconds, and staring at an empty table for that long feels
    /// broken. Rows appear progressively and the source name updates immediately.
    func scan(folder: URL) async {
        NSLog("音乐: scanning %@", folder.path)
        // A new scan supersedes whatever is running: bump the generation so the
        // previous pass stops committing rows and never writes its snapshot.
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        // A snapshot queued for the previous library must not land on top of
        // this one a second from now.
        saveTask?.cancel()
        saveTask = nil
        defer { if generation == scanGeneration { isScanning = false } }

        // Switching folders invalidates the filter and the ticked rows; a rescan
        // of the same folder should leave the user's search alone.
        let normalized = { (path: String?) -> String? in
            path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        let isSameFolder = normalized(activeFolderPath ?? defaults.string(forKey: folderKey))
            == normalized(folder.path)
        activeFolderPath = folder.path
        if !isSameFolder {
            filterText = ""
            checkedIDs.removeAll()
            // Ids from the previous library are not orphans of this one; keeping
            // them would carry a whole library's worth of paths forever.
            trackIDsByPath = [:]
        }

        sourceName = folder.lastPathComponent
        isDemoLibrary = false

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus", "mp4"]

        var found: [URL] = []
        if let en = fm.enumerator(at: folder,
                                  includingPropertiesForKeys: keys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in en {
                if audioExts.contains(fileURL.pathExtension.lowercased()) {
                    found.append(fileURL)
                }
            }
        }

        // Play counts, ratings and track ids live in `tracks`, not in the files,
        // so a rescan has to carry them over by path or it silently wipes them.
        // Read the *last complete* library, not `tracks`, which is published in
        // 250-track slices and may be half a scan behind.
        var previousByPath: [String: Track] = [:]
        for track in lastCompleteTracks {
            if let path = track.url?.path { previousByPath[path] = track }
        }
        // Ids survive even when the previous scan did not see the file at all.
        let knownIDs = trackIDsByPath

        var scanned: [Track] = []
        var art: [String: NSImage] = [:]
        let folderArtist = Self.artistHint(fromFolderName: folder.lastPathComponent)
        let batch = 250

        for url in found.prefix(20_000) {
            var t = Track(title: url.deletingPathExtension().lastPathComponent,
                          artist: folderArtist,
                          albumArtist: folderArtist,
                          album: url.deletingLastPathComponent().lastPathComponent,
                          url: url)

            // Filename heuristics: "01 Title" / "01 02 - Title"
            let base = url.deletingPathExtension().lastPathComponent
            if let m = Self.filenamePattern.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
               let titleRange = Range(m.range(at: m.numberOfRanges - 1), in: base) {
                if let numberRange = Range(m.range(at: 1), in: base) {
                    t.trackNumber = Int(base[numberRange]) ?? 0
                }
                t.title = String(base[titleRange]).trimmingCharacters(in: .whitespaces)
            }

            let asset = AVURLAsset(url: url)
            var embeddedArt: NSImage?

            if let meta = try? await asset.load(.commonMetadata) {
                for item in meta {
                    guard let key = item.commonKey else { continue }
                    switch key {
                    case .commonKeyTitle:
                        if let s = try? await item.load(.stringValue), !s.isEmpty { t.title = s }
                    case .commonKeyArtist:
                        if let s = try? await item.load(.stringValue), !s.isEmpty { t.artist = s }
                    case .commonKeyAlbumName:
                        if let s = try? await item.load(.stringValue), !s.isEmpty { t.album = s }
                    case .commonKeyArtwork:
                        if let data = try? await item.load(.dataValue), let img = NSImage(data: data) {
                            embeddedArt = img
                        }
                    default: break
                    }
                }
            }

            // The iTunes atoms AVFoundation maps without a common key: album artist,
            // release date, genre, disc and track numbers. Without these, imported
            // albums lose their grouping (album artist) and the 流派 / year columns.
            if let trackItems = try? await asset.load(.metadata) {
                for item in trackItems {
                    guard let id = item.identifier?.rawValue.lowercased() else { continue }
                    if id.contains("aart") {
                        if let s = try? await item.load(.stringValue), !s.isEmpty { t.albumArtist = s }
                    } else if id.contains("%a9day") || id.contains("tdrc") || id.contains("year") {
                        if let s = try? await item.load(.stringValue), let y = Int(s.prefix(4)) { t.year = y }
                    } else if id.contains("%a9gen") || id.contains("gnre") {
                        if let s = try? await item.load(.stringValue), !s.isEmpty { t.genre = s }
                    } else if id.contains("trkn") || id.contains("trck") {
                        if let s = try? await item.load(.stringValue) {
                            let leading = s.split(separator: "/").first.map(String.init) ?? s
                            if let n = Int(leading.trimmingCharacters(in: .whitespaces)) { t.trackNumber = n }
                        }
                    } else if id.contains("disk") || id.contains("tpos") {
                        if let s = try? await item.load(.stringValue) {
                            let leading = s.split(separator: "/").first.map(String.init) ?? s
                            if let n = Int(leading.trimmingCharacters(in: .whitespaces)) { t.discNumber = n }
                        }
                    } else if id.contains("covr"), embeddedArt == nil {
                        if let data = try? await item.load(.dataValue), let img = NSImage(data: data) {
                            embeddedArt = img
                        }
                    }
                }
            }
            if t.albumArtist.isEmpty { t.albumArtist = t.artist }

            if let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 {
                t.duration = d
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                    t.bitrate = max(1, Int(Double(size) * 8 / d / 1000))
                }
            }

            if let previous = previousByPath[url.path] {
                t.id = previous.id
                t.playCount = previous.playCount
                t.rating = previous.rating
                t.lastPlayed = previous.lastPlayed
            } else if let known = knownIDs[url.path] {
                t.id = known
            }

            let ext = url.pathExtension.lowercased()
            t.codec = (ext == "m4a" || ext == "aac") ? "AAC" : ext.uppercased()
            t.profile = (ext == "flac" || ext == "wav" || ext == "aiff") ? "PCM" : "LC"

            scanned.append(t)
            // Key the artwork by the *final* album key, which needs albumArtist.
            if let embeddedArt {
                art[t.albumKey] = embeddedArt
            }

            if scanned.count % batch == 0 {
                guard generation == scanGeneration, !Task.isCancelled else { return }
                tracks = scanned
                await Task.yield()
            }
        }

        guard generation == scanGeneration, !Task.isCancelled else { return }
        guard !scanned.isEmpty else {
            // A folder with no audio must not leave the previous library on
            // screen under the new source name, and the empty state has to reach
            // the disk too: `scheduleSave` refuses to run while `isScanning`, and
            // without this write the next launch would restore the old snapshot.
            tracks = []
            lastCompleteTracks = []
            selectedTrackID = nil
            filterText = ""
            checkedIDs.removeAll()
            // Nothing is on screen any more, so drop the decoded covers too
            // instead of letting them squat in the 96 MB cache.
            artworkCache.removeAllObjects()
            artworkMissing.removeAll()
            artworkLoading.removeAll()
            artworkUpgrades.removeAll()
            if let path = activeFolderPath ?? defaults.string(forKey: folderKey) {
                saveTask?.cancel()
                saveTask = nil
                cache.write(LibrarySnapshot(folderPath: path, savedAt: Date(),
                                                  tracks: [], playlists: playlists,
                                                  trackIDsByPath: orphanTrackIDs))
            }
            return
        }
        tracks = scanned
        lastCompleteTracks = scanned
        artworkCache.removeAllObjects()
        // A fresh scan may have read covers for albums that were previously
        // judged cover-less — including covers dropped into the cache directory
        // from outside — so the negative cache is dropped wholesale. The cost is
        // one extra decode attempt for albums that really have no cover.
        artworkMissing.removeAll()
        artworkLoading.removeAll()
        artworkUpgrades.subtract(art.keys)
        loadBundledArtwork()   // bundled demo art stays available as a fallback
        isDemoLibrary = false
        sourceName = folder.lastPathComponent
        // Select the first row the table will actually show, so the right panel
        // matches what the user sees instead of the first file on disk.
        selectedTrackID = groups.first?.tracks.first?.id ?? scanned.first?.id
        selectedSection = .library
        for track in scanned {
            if let path = track.url?.path { trackIDsByPath[path] = track.id }
        }

        let snapshot = LibrarySnapshot(folderPath: folder.path, savedAt: Date(),
                                       tracks: scanned, playlists: playlists,
                                       trackIDsByPath: orphanTrackIDs)
        // The writer owns its own serial queue, so the snapshot and its covers
        // land in one ordered pass; no detached task, no global override.
        cache.write(snapshot, artworks: art)
    }

    private static let filenamePattern = try! NSRegularExpression(
        pattern: #"^(\d{1,3})[\s\.\-]+(?:(\d{1,3})[\s\.\-]+)?(?:-\s*)?(.+)$"#
    )

    /// "鹿乃 - 鹿乃 Best Selection" -> "鹿乃"
    static func artistHint(fromFolderName name: String) -> String {
        if let r = name.range(of: " - ") {
            return String(name[name.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    // MARK: - Demo library (mirrors the reference screenshot)

    func loadDemoLibrary() {
        scanGeneration &+= 1
        tracks = DemoData.tracks
        lastCompleteTracks = DemoData.tracks
        playlists = []
        artworkCache.removeAllObjects()
        artworkMissing.removeAll()
        artworkLoading.removeAll()
        activeFolderPath = nil
        // A queued save for the real library would otherwise land after the demo
        // is on screen; it is harmless, but the asymmetry is not worth keeping.
        saveTask?.cancel()
        saveTask = nil
        filterText = ""
        checkedIDs.removeAll()
        loadBundledArtwork()
        isDemoLibrary = true
        sourceName = "示例资料库"
        selectedSection = .library
        selectedTrackID = tracks.first { $0.title == "キズナ" }?.id
    }
    /// Test hook: install a hand-built library without touching the disk.
    func replaceTracksForTesting(_ newTracks: [Track]) {
        scanGeneration &+= 1
        tracks = newTracks
        lastCompleteTracks = newTracks
        selectedTrackID = newTracks.first?.id
        selectedSection = .library
        viewMode = .playlist
        filterText = ""
    }

}
