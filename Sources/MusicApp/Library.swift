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
    /// How many files the last scan had to open and parse. The rest were reused
    /// from the snapshot because their mtime + size had not changed.
    private(set) var metadataReads = 0

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
    /// Decoded-cover notifications live on their own publisher; see `ArtworkTicker`.
    let artworkTicker = ArtworkTicker()
    private var artworkUpgrades: Set<String> = []
    private var artworkUpgradePassStarted = false
    /// Row id (`track:<uuid>`) the table should scroll into view. Row ids are
    /// strings because album headers are rows too.
    @Published var scrollTarget: String?
    /// Bumped on every reveal request. Comparing `scrollTarget` alone is not
    /// enough: asking to reveal the track that is already playing produces the
    /// same string, so the request would be swallowed.
    @Published private(set) var revealToken = 0
    /// When on, playback that moves to another track scrolls the table to it
    /// (auto-advance at the end of a song, next/previous, the top-bar button).
    @Published var followsPlayback = true

    var rowHeight: CGFloat { Metrics.rowHeight }

    private var contentVersion = 0
    /// Incremented on every scan; a pass whose generation no longer matches has
    /// been superseded and must not publish.
    private var scanGeneration = 0
    /// Covers are decoded bitmaps (~2.4 MB each at 768²), so the cache is capped
    /// by cost: browsing a large library must not grow memory without bound.
    private let artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 6
        return cache
    }()
    private var artworkMissing: Set<String> = []
    private var artworkLoading: Set<String> = []
    /// Row-sized covers, keyed `albumKey@side`. Kept apart from `artworkCache`
    /// because a 124px thumbnail is ~60 KB against the full cover's 2.36 MB, and
    /// the table asks for dozens of them while scrolling.
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        return cache
    }()
    /// Thumbnails currently being decoded.
    private var thumbnailLoading: Set<String> = []
    /// Last fully-published library. `tracks` itself is published in slices while
    /// a scan runs, so a rescan must not take its "previous" state from there.
    private var lastCompleteTracks: [Track] = []
    private var saveTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Exposed so the self-test can point a store at a scratch folder.
    static let folderKey = "library.folder.path"
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
        guard let path = defaults.string(forKey: Self.folderKey) else { return }
        // Opening the window must not walk 5,800 files. The snapshot written by
        // the last scan is used until the user asks for a rescan (⌘R).
        if let snapshot = cache.load(), snapshot.folderPath == path {
            // An empty snapshot is a real state (the folder was emptied), and its
            // playlists plus the id index have to come back with it.
            apply(snapshot)
            // An empty snapshot is a real state (the folder was emptied), and an
            // outdated one needs a re-parse: v1 saved every multi-disc album as
            // "disc 1, track 1". Either way the counts and playlists just loaded
            // are carried into the scan through `lastCompleteTracks`.
            let stale = snapshot.version < SnapshotWriter.version
            if (stale || snapshot.tracks.isEmpty), !cacheOnly,
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
    /// Hand the pages freed by a load/scan back to the OS. Without this the
    /// allocator keeps the JSON decode buffers and discarded bitmaps dirty for
    /// the life of the process, which is most of what "the app uses 130 MB"
    /// actually is.
    func releaseMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Relief twice, because the big transient buffers (JSON decode, discarded
    /// bitmaps) are released a beat after the load returns.
    private func scheduleMemoryRelief() {
        for delay in [0.35, 1.6] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                releaseMemory()
            }
        }
    }

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
        scheduleMemoryRelief()
    }

    /// Force a fresh walk of the imported folder and rewrite the snapshot.
    func rescan() {
        guard let path = defaults.string(forKey: Self.folderKey) else { return }
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
        guard !q.isEmpty else { return stampingDiscCounts(pool) }
        return stampingDiscCounts(pool.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.album.localizedCaseInsensitiveContains(q) ||
            $0.artist.localizedCaseInsensitiveContains(q) ||
            $0.albumArtist.localizedCaseInsensitiveContains(q) ||
            $0.genre.localizedCaseInsensitiveContains(q)
        })
    }

    /// Multi-disc rips restart track numbering on each disc, so the row needs the
    /// album's disc count to print "2-03" instead of a second bare "03". Snapshot
    /// tracks may not carry it (older caches), so stamp it here — one cheap pass
    /// over the filtered set, and every downstream path sees the same values.
    private func stampingDiscCounts(_ items: [Track]) -> [Track] {
        guard !items.isEmpty else { return items }
        var counts: [String: Int] = [:]
        for t in items { counts[t.albumKey] = max(counts[t.albumKey] ?? 1, max(1, t.discNumber)) }
        guard counts.values.contains(where: { $0 > 1 }) else { return items }
        return items.map { track in
            let n = counts[track.albumKey] ?? 1
            guard track.albumDiscCount != n else { return track }
            var copy = track
            copy.albumDiscCount = n
            return copy
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
    /// the bitmap arrives through `artworkTicker`. `artworkMissing` is a real
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
                artworkTicker.bump(album: albumKey)
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

    /// Cover decoded straight to `maxPixel`, for the table's 62pt thumbnails.
    /// Returns whatever is cached and kicks off a decode the first time, exactly
    /// like `artwork(for:)` — the row shows its placeholder for a frame or two.
    func thumbnail(for albumKey: String, maxPixel: Int) -> NSImage? {
        let key = "\(albumKey)@\(maxPixel)"
        if let image = thumbnailCache.object(forKey: key as NSString) { return image }
        // The full cover may already be in memory: downscaling that is cheap and
        // avoids touching the disk again.
        if let full = artworkCache.object(forKey: albumKey as NSString) {
            let image = Self.downscaled(full, maxPixel: maxPixel)
            if let image { thumbnailCache.setObject(image, forKey: key as NSString) }
            return image
        }
        // The offscreen renderer has no run loop, so the async decode below would
        // never land: read the thumbnail synchronously instead.
        if RenderMode.isOffscreen {
            guard let image = cache.readArtwork(for: albumKey, maxPixel: maxPixel) else { return nil }
            thumbnailCache.setObject(image, forKey: key as NSString)
            return image
        }
        guard !artworkMissing.contains(albumKey), !thumbnailLoading.contains(key) else { return nil }
        thumbnailLoading.insert(key)
        Task {
            let image = await decodeThumbnail(for: albumKey, maxPixel: maxPixel)
            thumbnailLoading.remove(key)
            if let image {
                thumbnailCache.setObject(image, forKey: key as NSString)
                artworkTicker.bump(album: albumKey)
                // Once the prefetch burst is done, return the decoder's pages.
                if thumbnailLoading.isEmpty { scheduleMemoryRelief() }
            } else {
                refreshArtwork(albumKey, ifSmallerThan: .infinity, markingMissingOnFailure: true)
            }
        }
        return nil
    }

    /// Pure cache read — no side effects, safe to call from a view body.
    func cachedThumbnail(for albumKey: String, maxPixel: Int) -> NSImage? {
        guard let image = thumbnailCache.object(forKey: "\(albumKey)@\(maxPixel)" as NSString) else {
            return nil
        }
        // A 768px cover already in memory is cheaper to downscale than to re-read.
        if let full = artworkCache.object(forKey: albumKey as NSString),
           let small = Self.downscaled(full, maxPixel: maxPixel) {
            thumbnailCache.setObject(small, forKey: "\(albumKey)@\(maxPixel)" as NSString)
            return small
        }
        return image
    }

    /// Async thumbnail for one album row. Rows call this from `.task`, so a
    /// finished decode only re-renders that row instead of invalidating the table.
    func thumbnailAsync(for albumKey: String, maxPixel: Int) async -> NSImage? {
        let key = "\(albumKey)@\(maxPixel)"
        if let cached = thumbnailCache.object(forKey: key as NSString) { return cached }
        if let full = artworkCache.object(forKey: albumKey as NSString),
           let small = Self.downscaled(full, maxPixel: maxPixel) {
            thumbnailCache.setObject(small, forKey: key as NSString)
            return small
        }
        if RenderMode.isOffscreen {
            if let image = cache.readArtwork(for: albumKey, maxPixel: maxPixel) {
                thumbnailCache.setObject(image, forKey: key as NSString)
                return image
            }
            return nil
        }
        guard !artworkMissing.contains(albumKey) else { return nil }
        thumbnailLoading.insert(key)
        let image = await decodeThumbnail(for: albumKey, maxPixel: maxPixel)
        thumbnailLoading.remove(key)
        if let image {
            thumbnailCache.setObject(image, forKey: key as NSString)
        } else {
            refreshArtwork(albumKey, ifSmallerThan: .infinity, markingMissingOnFailure: true)
        }
        return image
    }

    private func decodeThumbnail(for albumKey: String, maxPixel: Int) async -> NSImage? {
        let cache = self.cache
        return await Task.detached(priority: .userInitiated) {
            ArtworkBox(image: cache.readArtwork(for: albumKey, maxPixel: maxPixel))
        }.value.image
    }

    /// Downscale an in-memory cover to a square thumbnail.
    private static func downscaled(_ image: NSImage, maxPixel: Int) -> NSImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        guard cg.width > maxPixel || cg.height > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(max(cg.width, cg.height))
        let width = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
    }

    /// Warms the thumbnail cache for the next `limit` album headers. Called when
    /// the table appears and when the library changes, so scrolling into the
    /// second screenful does not show placeholders while covers decode.
    func prefetchThumbnails(maxPixel: Int, limit: Int = 48) {
        var seen: Set<String> = []
        for row in rows {
            guard seen.count < limit, let key = row.group?.albumKey, seen.insert(key).inserted else { continue }
            let cacheKey = "\(key)@\(maxPixel)"
            guard thumbnailCache.object(forKey: cacheKey as NSString) == nil,
                  !thumbnailLoading.contains(cacheKey) else { continue }
            _ = thumbnail(for: key, maxPixel: maxPixel)
        }
        // The prefetch decodes a screenful of bitmaps; hand back what the
        // decoders used once they are done.
        scheduleMemoryRelief()
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
            artworkTicker.bump(album: albumKey)
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
                    artworkTicker.bump(album: albumKey)
                    await Task.yield()
                }
            }
            if done > 0 {
                artworkTicker.bump(album: "")
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
        revealToken &+= 1
    }

    /// Programmatic "scroll here" used by the debug switches and the tests.
    func requestScroll(to rowID: String) {
        scrollTarget = rowID
        revealToken &+= 1
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
        guard let path = activeFolderPath ?? defaults.string(forKey: Self.folderKey) else { return }
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
        guard let path = activeFolderPath ?? defaults.string(forKey: Self.folderKey) else { return }
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
            defaults.set(url.path, forKey: Self.folderKey)
            Task { await self.scan(folder: url) }
        }
    }

    func clearImportedLibrary() {
        defaults.removeObject(forKey: Self.folderKey)
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
    /// One audio file as the enumerator reported it: the URL plus the cheap
    /// fingerprint used to decide whether its tags have to be read again.
    struct AudioFile: Sendable {
        let url: URL
        let mtime: Date?
        let size: Int64?

        func isUnchanged(since track: Track) -> Bool {
            track.fileMtime == mtime && track.fileSize == size && track.duration > 0
        }
    }

    /// What a worker hands back to the main actor. `Data` rather than `NSImage`
    /// keeps the boundary a value type.
    struct ParsedFile: Sendable {
        let index: Int
        let track: Track
        let artwork: Data?
    }

    /// Reads one file's tags off the main actor. Everything here is either a
    /// value type or AVFoundation's own async API.
    nonisolated static func parse(_ file: AudioFile,
                                  index: Int,
                                  folderArtist: String,
                                  previous: Track?,
                                  knownID: UUID?) async -> ParsedFile {
        var t = Track(title: file.url.deletingPathExtension().lastPathComponent,
                      artist: folderArtist,
                      albumArtist: folderArtist,
                      album: file.url.deletingLastPathComponent().lastPathComponent,
                      url: file.url)

        // Filename heuristics: "01 Title" / "01 02 - Title"
        let base = file.url.deletingPathExtension().lastPathComponent
        if let m = filenamePattern.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let titleRange = Range(m.range(at: m.numberOfRanges - 1), in: base) {
            let first = Range(m.range(at: 1), in: base).flatMap { Int(base[$0]) }
            let second = m.range(at: 2).location == NSNotFound
                ? nil
                : Range(m.range(at: 2), in: base).flatMap { Int(base[$0]) }
            // "01 11 - Title" is a disc/track pair from a multi-disc rip: the first
            // number is the disc, the second the track. "01 - Title" stays a plain
            // track number.
            if let first, let second, first <= 9 {
                t.discNumber = first
                t.trackNumber = second
            } else {
                t.trackNumber = first ?? 0
            }
            t.title = String(base[titleRange]).trimmingCharacters(in: .whitespaces)
        }

        let asset = AVURLAsset(url: file.url)
        var artworkData: Data?

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
                    if let data = try? await item.load(.dataValue) { artworkData = data }
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
                    if let n = await Self.number(from: item) { t.trackNumber = n }
                } else if id.contains("disk") || id.contains("tpos") {
                    if let n = await Self.number(from: item) { t.discNumber = n }
                } else if id.contains("covr"), artworkData == nil {
                    if let data = try? await item.load(.dataValue) { artworkData = data }
                }
            }
        }
        if t.albumArtist.isEmpty { t.albumArtist = t.artist }

        if let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 {
            t.duration = d
            if let size = file.size, size > 0 {
                t.bitrate = max(1, Int(Double(size) * 8 / d / 1000))
            }
        }

        // Stats and identity always come from the previous library, whether or
        // not its tags were reused.
        if let previous {
            t.id = previous.id
            t.playCount = previous.playCount
            t.rating = previous.rating
            t.lastPlayed = previous.lastPlayed
        } else if let knownID {
            t.id = knownID
        }
        t.fileMtime = file.mtime
        t.fileSize = file.size

        let ext = file.url.pathExtension.lowercased()
        t.codec = (ext == "m4a" || ext == "aac") ? "AAC" : ext.uppercased()
        t.profile = (ext == "flac" || ext == "wav" || ext == "aiff") ? "PCM" : "LC"

        return ParsedFile(index: index, track: t, artwork: artworkData)
    }

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
        let isSameFolder = normalized(activeFolderPath ?? defaults.string(forKey: Self.folderKey))
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
        // `contentModificationDate` + `fileSize` come for free from the enumerator
        // and are the fingerprint an incremental rescan needs.
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus", "mp4"]

        var found: [AudioFile] = []
        if let en = fm.enumerator(at: folder,
                                  includingPropertiesForKeys: keys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in en {
                guard audioExts.contains(fileURL.pathExtension.lowercased()) else { continue }
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                found.append(AudioFile(url: fileURL,
                                       mtime: values?.contentModificationDate,
                                       size: values?.fileSize.map(Int64.init)))
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

        let started = Date()
        let folderArtist = Self.artistHint(fromFolderName: folder.lastPathComponent)
        let batch = 250

        // One slot per file keeps the order stable while the tags are read
        // concurrently; a slot is filled either by reusing the previous parse or
        // by a worker, and the table shows whatever is already filled.
        var slots = [Track?](repeating: nil, count: found.count)
        // The index carried here is the position in `found`, not in `pending`:
        // a worker's result has to land in the slot its file came from, or any
        // reused file ahead of it would make the two sequences disagree and one
        // slot would be written twice while another stays empty.
        var pending: [(index: Int, file: AudioFile)] = []
        var reused = 0
        for (index, file) in found.enumerated() {
            guard let previous = previousByPath[file.url.path],
                  file.isUnchanged(since: previous) else {
                pending.append((index: index, file: file))
                continue
            }
            // Nothing moved: the parsed tags, the play count and the id all come
            // straight from the previous library, no file is opened.
            slots[index] = previous
            reused += 1
            if reused % batch == 0 { tracks = slots.compactMap { $0 } }
        }
        if reused > 0 { tracks = slots.compactMap { $0 } }

        var art: [String: NSImage] = [:]
        var parsed = 0
        metadataReads = 0

        await withTaskGroup(of: ParsedFile.self) { group in
            var next = 0
            let width = 8
            func addNext() {
                guard next < pending.count else { return }
                let (index, file) = pending[next]
                next += 1
                let previous = previousByPath[file.url.path]
                group.addTask {
                    await Self.parse(file, index: index,
                                     folderArtist: folderArtist,
                                     previous: previous,
                                     knownID: knownIDs[file.url.path])
                }
            }
            for _ in 0..<min(width, pending.count) { addNext() }

            for await result in group {
                guard generation == scanGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                slots[result.index] = result.track
                if let data = result.artwork, let image = NSImage(data: data) {
                    art[result.track.albumKey] = image
                }
                parsed += 1
                metadataReads += 1
                addNext()
                if parsed % batch == 0 {
                    tracks = slots.compactMap { $0 }
                    await Task.yield()
                }
            }
        }
        guard generation == scanGeneration, !Task.isCancelled else { return }

        let ordered = slots.compactMap { $0 }
        scheduleMemoryRelief()
        NSLog("音乐: scan finished in %.1fs — %d files, %d parsed, %d reused",
              Date().timeIntervalSince(started), ordered.count, parsed, reused)

        // Stamp each album with its disc count so the table can show "2-03"
        // for multi-disc rips instead of a bare number that repeats per disc.
        var discCounts: [String: Int] = [:]
        for track in ordered {
            discCounts[track.albumKey] = max(discCounts[track.albumKey] ?? 1, max(1, track.discNumber))
        }
        let scanned: [Track] = ordered.map { track in
            var copy = track
            copy.albumDiscCount = discCounts[track.albumKey] ?? 1
            return copy
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
            thumbnailCache.removeAllObjects()
            thumbnailLoading.removeAll()
            artworkMissing.removeAll()
            artworkLoading.removeAll()
            artworkUpgrades.removeAll()
            if let path = activeFolderPath ?? defaults.string(forKey: Self.folderKey) {
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

    /// `trkn` / `disk` are **binary** iTunes atoms: two reserved bytes, then
    /// big-endian UInt16 value and total. They expose no `stringValue`, so reading
    /// them as a string silently produced nothing (which is why every file of a
    /// multi-disc album ended up as "disc 1, track 1"). `trck` / `tpos` are the
    /// ID3-style "11/19" strings.
    private static func number(from item: AVMetadataItem) async -> Int? {
        if let data = try? await item.load(.dataValue) {
            let bytes = [UInt8](data)
            if bytes.count >= 4 {
                let value = Int(bytes[bytes.count >= 4 ? 2 : 0]) << 8 | Int(bytes[3])
                if value > 0 { return value }
            }
        }
        if let s = try? await item.load(.stringValue) {
            let leading = s.split(separator: "/").first.map(String.init) ?? s
            if let n = Int(leading.trimmingCharacters(in: .whitespaces)), n > 0 { return n }
        }
        if let n = try? await item.load(.numberValue)?.intValue, n > 0 { return n }
        return nil
    }

    nonisolated private static let filenamePattern = try! NSRegularExpression(
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
