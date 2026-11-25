import AppKit
import SwiftUI
import Foundation
import AVFoundation

/// Headless smoke test: `音乐 --self-test [folder]`
///
/// Exercises the two halves that cannot be checked by looking at a screenshot —
/// the metadata scan of real files and real playback through `AVAudioPlayer` —
/// then prints a report and exits. It never opens a window, so it is safe to run
/// from a terminal while the app itself is closed.
@MainActor
enum SelfTest {
    /// Every store the suite builds must write into the scratch directory, so a
    /// check can never touch the user's real snapshot.
    private static var scratchCache = SnapshotWriter(
        directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-selftest-uninitialised", isDirectory: true))

    private static func makeStore(cacheOnly: Bool = false) -> LibraryStore {
        LibraryStore(autoLoad: false, cacheOnly: cacheOnly, cache: scratchCache)
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--resource-check") {
            runResourceCheck()
            return
        }
        guard args.contains("--self-test") else { return }

        let folder: URL
        if let index = args.firstIndex(of: "--self-test"), index + 1 < args.count,
           !args[index + 1].hasPrefix("--") {
            folder = URL(fileURLWithPath: args[index + 1])
        } else {
            folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Plex")
        }

        // Sandbox the whole run: the initial scan writes a snapshot, and the
        // point of a self test is never to touch the user's real library.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-selftest-\(UUID().uuidString)", isDirectory: true)
        scratchCache = SnapshotWriter(directory: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // On a machine without the sample library, fall back to a fixture the
        // test writes itself, so the suite never degrades into "everything passed
        // because nothing ran".
        var scanFolder = folder
        if !FileManager.default.fileExists(atPath: scanFolder.path) {
            let fixture = scratch.appendingPathComponent("fixture", isDirectory: true)
            try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let names = [
                "01 - Alpha.wav", "02 - Bravo.wav", "03 - Charlie.wav", "04 - Delta.wav",
                "05 - Echo.wav", "06 - Foxtrot.wav", "07 - Golf.wav", "08 - Hotel.wav",
            ]
            var made = 0
            // Long enough for the playback check to observe progress before the
            // track ends and rewinds to zero.
            for name in names where makeTestAudio(in: fixture, name: name, seconds: 6) != nil {
                made += 1
            }
            guard made == names.count else {
                print("selftest: FAIL the sample library is missing and the fixture could not be written")
                exit(1)
            }
            scanFolder = fixture
            print("selftest: \(folder.path) not found — using a generated fixture of \(made) files")
        }

        print("selftest: scanning \(scanFolder.path)")
        let store = makeStore()
        var finished = false
        Task { @MainActor in
            await store.scan(folder: scanFolder)
            finished = true
        }
        wait(until: { finished }, timeout: 30)

        let tracks = store.tracks
        print("selftest: \(tracks.count) tracks, \(store.groups.count) albums")
        for track in tracks.prefix(3) {
            print("  • \(track.artist) — \(track.title) [\(track.album)] \(track.formatText)")
        }
        guard let first = tracks.first else {
            print("selftest: FAIL no tracks found")
            exit(1)
        }

        print("selftest: artwork keys = \(store.artworkCount), first album key = \(first.albumKey.debugDescription)")

        let player = PlayerEngine()
        player.play(first, in: tracks)
        wait(until: { player.progress > 0.5 }, timeout: 8)
        let reported = player.duration
        let elapsed = player.progress
        player.pause()
        let paused = player.progress
        wait(seconds: 0.6)
        let afterPause = player.progress

        print(String(format: "selftest: played %.2fs of %.2fs, paused at %.2fs, %.2fs later %.2fs",
                     elapsed, reported, paused, 0.6, afterPause))

        let okPlayback = elapsed > 0.5 && reported > 1
        let okPause = abs(afterPause - paused) < 0.3
        let okCache = checkCacheRoundTrip(store, folder: folder)
        let okGroups = checkArtistGroups(store)
        let okOrder = checkOrder(store) && checkDiscOrder()
        let okSort = checkColumnSort(store)
        let okModes = checkPlayModes()
        let okPalette = checkPalette()
        let okSpectrum = checkSpectrum()
        let okRestore = checkPlaybackMemory()
        let okDerived = checkDerivedCache(store)
        let okReveal = checkRevealRequests(store)
        let okDiscLabels = checkDiscLabels()
        let okRescan = checkRescanKeepsStats()
        let okIncremental = checkIncrementalScan()
        let okPlaylists = checkPlaylists(store)
        let okEmptyScan = checkEmptyScanPersists()
        let okOrdering = checkSnapshotOrdering()
        let okStableIDs = checkPlaylistSurvivesEmptyScan()
        let okRowIDs = checkRowIDs()
        let okPaletteAsync = checkPaletteAsyncArrival()
        let okPlaylistRoundTrip = checkPlaylistRoundTrip(store)
        let ok = okPlayback && okPause && okOrder && okSort && okCache && okGroups
            && okModes && okPalette && okRestore && okSpectrum && okDerived && okRescan && okReveal && okDiscLabels
            && okIncremental
            && okPlaylists && okRowIDs && okPaletteAsync && okPlaylistRoundTrip && okEmptyScan
            && okOrdering
        print("selftest: \(ok ? "PASS" : "FAIL") (playback=\(okPlayback), pause=\(okPause), order=\(okOrder), sort=\(okSort), cache=\(okCache), groups=\(okGroups), modes=\(okModes), palette=\(okPalette), restore=\(okRestore), spectrum=\(okSpectrum), derived=\(okDerived), rescan=\(okRescan), playlists=\(okPlaylists), rowids=\(okRowIDs), palettelate=\(okPaletteAsync), playlistio=\(okPlaylistRoundTrip), emptyscan=\(okEmptyScan), stableids=\(okStableIDs), ordering=\(okOrdering), incremental=\(okIncremental), reveal=\(okReveal), disclabels=\(okDiscLabels))")
        exit(ok ? 0 : 1)
    }

    /// A cache hit must reproduce the scan exactly; that is the whole point of
    /// not walking the disk at launch.
    /// Verifies the resource bundle resolves from *inside* the app, which is the
    /// one thing that cannot be tested on the build machine by launching the app:
    /// SwiftPM's fallback path to `.build` makes that work locally and hides the
    /// bug until the app reaches someone else's Mac.
    private static func runResourceCheck() {
        let app = Bundle.main.bundleURL
        let path = AppResources.location
        let inside = path.hasPrefix(app.path)
        let cover = AppResources.bundle.url(forResource: "cover-dawn", withExtension: "png") != nil
        print("resource-check: bundle = \(path)")
        print("resource-check: inside app = \(inside)")
        print("resource-check: demo cover = \(cover)")
        let ok = inside && cover
        print("resource-check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }

    private static func checkCacheRoundTrip(_ store: LibraryStore, folder: URL) -> Bool {
        let snapshot = LibrarySnapshot(folderPath: folder.path, savedAt: Date(), tracks: store.tracks)
        store.cache.flush(snapshot)
        guard let loaded = store.cache.load() else {
            print("selftest: cache reload failed")
            return false
        }
        guard loaded.tracks.count == store.tracks.count, loaded.folderPath == folder.path else {
            print("selftest: cache mismatch \(loaded.tracks.count) vs \(store.tracks.count)")
            return false
        }
        // Spot-check a field that comes from the iTunes atoms rather than the filename.
        let sortedA = store.tracks.sorted { $0.album < $1.album }
        let sortedB = loaded.tracks.sorted { $0.album < $1.album }
        if let a = sortedA.first(where: { !$0.album.isEmpty }), let b = sortedB.first(where: { $0.album == a.album }),
           a.albumArtist != b.albumArtist || a.duration != b.duration {
            print("selftest: cache field drift on \(a.title)")
            return false
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.cache.snapshotURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        print("selftest: cache round-trip ok (\(loaded.tracks.count) tracks, \(size / 1024)KB at \(store.cache.snapshotURL.path))")
        return true
    }

    // MARK: - Ordering

    /// The grouped table must read artist → album → disc → track, and playback
    /// must follow the same sequence.
    /// The table reads `store.rows` from `body`; it must be memoised, otherwise
    /// every click and every palette change re-sorts the whole library.
    /// A rescan must not wipe play counts, ratings or track identity: those live
    /// in the snapshot keyed by file path, not in the files themselves.
    /// Writes a short self-made WAV so the scan tests do not depend on the user's
    /// music folder existing (on a fresh machine they would silently skip).
    private static func makeTestAudio(in folder: URL, name: String, seconds: Double = 2) -> URL? {
        let url = folder.appendingPathComponent(name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        else { return nil }
        // WAV files cannot be non-interleaved; asking for interleaved output keeps
        // CoreAudio from logging a warning for every fixture file.
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(44_100 * seconds))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(44_100 * seconds)
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    channels[channel][frame] = 0.05 * sinf(2 * .pi * 440 * Float(frame) / 44_100)
                }
            }
        }
        do { try file.write(from: buffer) } catch { return nil }
        return url
    }

    /// A rescan must not re-read tags for files that did not change: that is the
    /// difference between 13-17s and 0.3s on a 5,800-track library. Touching one
    /// file's mtime must cost exactly one re-parse.
    /// A multi-disc rip restarts numbering per disc, so the row must print the
    /// disc as well; single-disc albums keep the plain "03".
    @MainActor
    private static func checkDiscLabels() -> Bool {
        var single = Track(title: "x", artist: "a", albumArtist: "a", album: "Single", url: nil)
        single.trackNumber = 3
        single.albumDiscCount = 1

        var multi = Track(title: "y", artist: "a", albumArtist: "a", album: "Multi", url: nil)
        multi.trackNumber = 3
        multi.discNumber = 2
        multi.albumDiscCount = 3

        let ok = single.numberLabel == "03" && multi.numberLabel == "2-03"
        print("selftest: disc labels — single \(single.numberLabel), multi \(multi.numberLabel): \(ok)")
        return ok
    }

    /// Asking to reveal the track that is already playing used to be swallowed:
    /// the request was "scroll to <row id>", and the coordinator skipped it when
    /// the id matched the previous request. Two reveals of the same track must
    /// therefore bump the request token twice.
    @MainActor
    private static func checkRevealRequests(_ store: LibraryStore) -> Bool {
        guard let track = store.allVisibleTracks.first(where: { $0.url != nil })
                ?? store.allVisibleTracks.first else { return false }
        store.selectedSection = .library
        store.viewMode = .playlist
        let before = store.revealToken

        store.reveal(trackID: track.id, force: true)
        let firstTarget = store.scrollTarget
        let firstToken = store.revealToken

        store.scrollTarget = nil          // what the coordinator does after scrolling
        store.reveal(trackID: track.id, force: true)
        let secondTarget = store.scrollTarget
        let secondToken = store.revealToken

        store.scrollTarget = nil
        let rowID = "track:" + track.id.uuidString
        let ok = firstTarget == rowID
            && secondTarget == rowID
            && firstToken == before &+ 1
            && secondToken == before &+ 2
        print("selftest: reveal — repeat request reaches the table: \(ok)"
            + " (tokens \(before) → \(firstToken) → \(secondToken))")
        return ok
    }

    private static func checkIncrementalScan() -> Bool {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-selftest-incremental-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        var made = 0
        for index in 1...3 where makeTestAudio(in: folder, name: "gap-\(index).wav") != nil {
            made += 1
        }
        guard made == 3 else {
            print("selftest: incremental — FAIL could not write test audio")
            return false
        }

        let store = makeStore()
        var done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        let firstRun = store.metadataReads
        let counted = store.tracks.count

        done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        let secondRun = store.metadataReads
        let stillCounted = store.tracks.count

        // Touch exactly one file, so exactly one tag read is expected.
        let touched = folder.appendingPathComponent("gap-2.wav")
        let future = Date().addingTimeInterval(3600)
        try? fm.setAttributes([.modificationDate: future], ofItemAtPath: touched.path)

        done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        let thirdRun = store.metadataReads

        let parsedOnce = firstRun == 3
        let reusedAll = secondRun == 0 && stillCounted == counted
        let onlyTouched = thirdRun == 1 && store.tracks.count == counted
        print("selftest: incremental — parsed=\(firstRun) reused=\(counted - firstRun), "
              + "second=\(secondRun), after-touch=\(thirdRun), tracks=\(store.tracks.count)")
        return parsedOnce && reusedAll && onlyTouched
    }

    private static func checkRescanKeepsStats() -> Bool {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-selftest-rescan-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        // Self-contained fixture: three short tones written by the test itself.
        var made = 0
        for index in 1...3 where makeTestAudio(in: folder, name: "fixture-\(index).wav") != nil {
            made += 1
        }
        guard made == 3 else {
            print("selftest: rescan — FAIL could not write test audio")
            return false
        }

        let store = makeStore()
        var done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        guard let first = store.tracks.first else {
            print("selftest: rescan — FAIL scan produced no tracks")
            return false
        }
        let id = first.id
        store.notePlay(first)
        store.notePlay(first)
        store.setRating(4, for: id)
        let before = store.tracks.first { $0.id == id }

        done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        let after = store.tracks.first { $0.url?.path == before?.url?.path }
        let kept = after?.playCount == 2 && after?.rating == 4 && after?.id == id
        print("selftest: rescan — counts kept=\(after?.playCount == 2), rating kept=\(after?.rating == 4), id stable=\(after?.id == id)")
        return kept
    }

    /// A playlist must actually scope the table, not just highlight a sidebar row.
    /// Scanning an empty folder has to reach the disk: otherwise the next launch
    /// restores the previous (non-empty) snapshot and the empty state is lost
    /// until the user rescans and quits in the right order.
    /// Bookkeeping the writer queue and the test thread both touch.
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The snapshot queue must land writes in order (the last one wins) and must
    /// not sit behind cover encoding: a hundred queued covers used to make
    /// quitting wait seconds, because `flush` was synchronous on the same queue.
    private static func checkSnapshotOrdering() -> Bool {
        let store = makeStore()
        let folder = URL(fileURLWithPath: "/tmp/music-order-test")
        let sample = (0..<4000).map { index -> Track in
            Track(title: "order-\(index)", artist: "A", albumArtist: "A",
                  album: "Ordering", genre: "Test", trackNumber: index + 1,
                  discNumber: 1, year: 2026, duration: 1, url: nil,
                  codec: "PCM", bitrate: 0, profile: "LC", playCount: 0,
                  rating: 0, lastPlayed: nil, lyricist: "", composer: "", lyrics: [])
        }

        // Sizes descend on purpose: a big snapshot queued earlier used to finish
        // after a smaller one queued later and leave a stale library on disk.
        let ranOffMain = FlagBox()
        for count in [sample.count, 800, 5] {
            store.cache.write(LibrarySnapshot(folderPath: folder.path, savedAt: Date(),
                                              tracks: Array(sample.prefix(count))),
                              completion: { if !Thread.isMainThread { ranOffMain.set() } })
        }
        store.cache.drainSnapshots()
        guard let loaded = store.cache.load() else {
            print("selftest: snapshot ordering — FAIL nothing on disk")
            return false
        }
        let newest = loaded.tracks.count == 5

        // Covers must not delay the snapshot. Hold the cover queue with a
        // semaphore so its progress is deterministic, then hand the writer one
        // batch (the shape a scan end produces: snapshot + covers) and flush a
        // newer snapshot. The JSON must already be current while the batch has
        // not finished — on a single queue `flush` would have to wait for the
        // whole batch, and the "batch done" marker would already be set.
        let gate = DispatchSemaphore(value: 0)
        let batchDone = FlagBox()
        // Bounded wait: if a regression puts covers back on the snapshot queue,
        // this gate is ahead of `flush` on that queue and an unbounded wait would
        // deadlock the whole self-test. After 5s it lets go and the assertions
        // below fail cleanly (marker set ⇒ flush waited for covers).
        store.cache.enqueueArtworkForTesting { _ = gate.wait(timeout: .now() + 5) }

        let image = NSImage(size: NSSize(width: 512, height: 512))
        let keys = (0..<100).map { "order-cover-\($0)" }
        store.cache.write(LibrarySnapshot(folderPath: folder.path, savedAt: Date(),
                                          tracks: Array(sample.prefix(40))),
                          artworks: Dictionary(uniqueKeysWithValues: keys.map { ($0, image) }))
        store.cache.enqueueArtworkForTesting { batchDone.set() }
        store.cache.flush(LibrarySnapshot(folderPath: folder.path, savedAt: Date(),
                                          tracks: Array(sample.prefix(3))))

        let flushed = store.cache.load()?.tracks.count == 3
        let flushIgnoredCovers = flushed && !batchDone.isSet
        gate.signal()
        store.cache.drainArtwork()
        let coversLanded = keys.allSatisfy {
            FileManager.default.fileExists(atPath: store.cache.artworkURL(for: $0).path)
        }

        // What a quit would block on, in the shape of the real case: 1,000 covers
        // queued and one snapshot to flush.
        let batch = NSImage(size: NSSize(width: 512, height: 512))
        let bulk = Dictionary(uniqueKeysWithValues: (0..<1000).map { ("order-bulk-\($0)", batch) })
        store.cache.write(LibrarySnapshot(folderPath: folder.path, savedAt: Date(),
                                          tracks: Array(sample.prefix(20))), artworks: bulk)
        let started = Date()
        store.cache.flush(LibrarySnapshot(folderPath: folder.path, savedAt: Date(),
                                          tracks: Array(sample.prefix(2))))
        let flushMs = Int(Date().timeIntervalSince(started) * 1000)
        store.cache.drainArtwork()

        let ok = newest && ranOffMain.isSet && flushIgnoredCovers && coversLanded
        print("selftest: snapshot ordering — newest=\(newest), off-main=\(ranOffMain.isSet), flush-ignores-covers=\(flushIgnoredCovers), covers-land=\(coversLanded), flush with 1,000 covers queued=\(flushMs)ms")
        return ok
    }

    private static func checkEmptyScanPersists() -> Bool {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-selftest-empty-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let store = makeStore()
        var done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 20)

        guard store.tracks.isEmpty else {
            print("selftest: empty scan — FAIL scan produced \(store.tracks.count) tracks")
            return false
        }
        guard let snapshot = store.cache.load() else {
            print("selftest: empty scan — FAIL no snapshot written")
            return false
        }
        let ok = snapshot.tracks.isEmpty && snapshot.folderPath == folder.path
        print("selftest: empty scan — saved \(snapshot.tracks.count) tracks for \(snapshot.folderPath) → \(ok)")
        return ok
    }

    /// A playlist's ids have to survive a scan that cannot see the files at all,
    /// *and* a relaunch in that state: the empty scan wipes `lastCompleteTracks`,
    /// so only a snapshot carrying the index can bring the ids back.
    private static func checkPlaylistSurvivesEmptyScan() -> Bool {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-selftest-ids-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        // Self-contained fixture: two short tones, rewritten later to "put the
        // files back" at exactly the same paths.
        let names = ["id-fixture-1.wav", "id-fixture-2.wav"]
        for name in names where makeTestAudio(in: folder, name: name) == nil {
            print("selftest: stable ids — FAIL could not write test audio")
            return false
        }
        let paths = names.map { folder.appendingPathComponent($0) }

        let store = makeStore()
        var done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        guard !store.tracks.isEmpty else {
            print("selftest: stable ids — FAIL first scan produced no tracks")
            return false
        }
        let playlist = store.addPlaylist()
        let ids = Array(store.tracks.prefix(2).map(\.id))
        for id in ids { store.addToPlaylist(id, playlistID: playlist.id) }
        store.flushSnapshot()

        // The folder becomes empty: the library clears, the playlist keeps its ids.
        for file in paths { try? fm.removeItem(at: file) }
        done = false
        Task { @MainActor in await store.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        guard store.tracks.isEmpty else {
            print("selftest: stable ids — FAIL empty scan still shows \(store.tracks.count) tracks")
            return false
        }
        guard store.playlists.first?.trackIDs.count == 2 else {
            print("selftest: stable ids — FAIL playlist lost its members on the empty scan")
            return false
        }

        // The empty state has to be on disk, index included — otherwise a relaunch
        // comes back with neither the playlist nor the ids.
        guard let snapshot = store.cache.load(),
              snapshot.tracks.isEmpty,
              snapshot.playlists?.count == 1,
              (snapshot.trackIDsByPath?.count ?? 0) >= 2 else {
            print("selftest: stable ids — FAIL snapshot missing playlists or id index")
            return false
        }
        // Relaunch: a fresh store adopts the snapshot, exactly like `init` does.
        let revived = makeStore()
        revived.adoptSnapshotForTesting(snapshot)
        guard revived.playlists.first?.trackIDs.count == 2 else {
            print("selftest: stable ids — FAIL relaunched store lost the playlist")
            return false
        }

        // Put the files back at the same paths; the ids must resolve again — in
        // the revived store.
        var restored = 0
        for name in names where makeTestAudio(in: folder, name: name) != nil { restored += 1 }
        guard restored == names.count else {
            print("selftest: stable ids — FAIL could not restore the fixture")
            return false
        }
        done = false
        Task { @MainActor in await revived.scan(folder: folder); done = true }
        wait(until: { done }, timeout: 30)
        let resolved = ids.filter { revived.track(id: $0) != nil }.count
        print("selftest: stable ids — \(resolved)/2 playlist members resolved after relaunch + folder restored")
        return resolved == 2
    }

    private static func checkPlaylists(_ store: LibraryStore) -> Bool {
        let picks = Array(store.tracks.prefix(2))
        guard picks.count == 2 else {
            print("selftest: playlists — skipped (not enough tracks)")
            return true
        }
        let playlist = store.addPlaylist()
        for track in picks { store.addToPlaylist(track.id, playlistID: playlist.id) }
        store.selectedPlaylistID = playlist.id
        let scoped = store.allVisibleTracks.map(\.id)
        let scopedOK = scoped.count == 2 && Set(scoped) == Set(picks.map(\.id))

        // Deleting it drops the scope instead of leaving a dangling id.
        store.removePlaylist(playlist.id)
        let cleared = store.selectedPlaylistID == nil && store.allVisibleTracks.count == store.tracks.count
        print("selftest: playlists — scoped=\(scopedOK) cleared=\(cleared)")
        return scopedOK && cleared
    }

    private static func checkDerivedCache(_ store: LibraryStore) -> Bool {
        _ = store.rows
        let baseline = store.derivedRebuilds
        for _ in 0..<200 { _ = store.rows.count }
        let unchanged = store.derivedRebuilds == baseline

        // Selection-only changes must not invalidate the row list either.
        let previous = store.selectedTrackID
        store.selectedTrackID = store.rows.compactMap(\.track).last?.id
        for _ in 0..<50 { _ = store.rows.count }
        let untouched = store.derivedRebuilds == baseline
        store.selectedTrackID = previous

        // …while a real input change must rebuild exactly once.
        let filter = store.filterText
        store.filterText = "a"
        _ = store.rows
        let rebuiltOnce = store.derivedRebuilds == baseline + 1
        store.filterText = filter
        _ = store.rows

        // Cost of a rebuild, so a regression shows up as a number.
        let start = Date()
        store.filterText = "zzz"
        _ = store.rows
        let emptyMs = Date().timeIntervalSince(start) * 1000
        store.filterText = ""
        let startFull = Date()
        _ = store.rows
        let fullMs = Date().timeIntervalSince(startFull) * 1000
        print(String(format: "selftest: derived cache — memoised=%@ selection-stable=%@ rebuild-once=%@ (full rebuild %.1f ms, empty %.1f ms, %d tracks)",
                     unchanged ? "true" : "false", untouched ? "true" : "false",
                     rebuiltOnce ? "true" : "false", fullMs, emptyMs, store.tracks.count))
        return unchanged && untouched && rebuiltOnce
    }

    private static func checkOrder(_ store: LibraryStore) -> Bool {
        let visible = store.allVisibleTracks
        guard visible.count > 1 else { return false }
        for i in 1..<visible.count where !libraryOrdered(visible[i - 1], visible[i]) {
            print("selftest: order broken at \(i): \(describe(visible[i - 1])) → \(describe(visible[i]))")
            return false
        }
        // Disc numbers must actually exist somewhere, otherwise the disc-level
        // assertion above never runs on real data.
        let multiDisc = store.tracks.filter { $0.discNumber > 1 }.count
        print("selftest: rows ordered artist → album → disc → track (\(multiDisc) tracks beyond disc 1)")
        return true
    }

    /// Artist / genre groups span many albums, so their songs must be ordered
    /// album by album — otherwise every album's "01" stacks at the top of the
    /// group (which is exactly how this looked to the user).
    private static func checkArtistGroups(_ store: LibraryStore) -> Bool {
        let previousMode = store.viewMode
        store.viewMode = .artists
        defer { store.viewMode = previousMode }

        var checkedGroups = 0, checkedTracks = 0
        for group in store.groups {
            let tracks = group.tracks
            guard tracks.count > 1 else { continue }
            checkedGroups += 1
            checkedTracks += tracks.count
            var seenAlbums: Set<String> = []
            for i in 1..<tracks.count {
                let a = tracks[i - 1], b = tracks[i]
                let album = a.album.localizedStandardCompare(b.album)
                if album == .orderedSame {
                    if a.discNumber != b.discNumber ? a.discNumber > b.discNumber : a.trackNumber > b.trackNumber {
                        print("selftest: artist group \(group.album) out of track order at \(i)")
                        return false
                    }
                } else {
                    if album == .orderedDescending {
                        print("selftest: artist group \(group.album) albums out of order at \(i): \(a.album) → \(b.album)")
                        return false
                    }
                    if seenAlbums.contains(b.album) {
                        print("selftest: artist group \(group.album) album blocks interleaved at \(i): \(b.album)")
                        return false
                    }
                    seenAlbums.insert(a.album)
                }
            }
        }
        guard checkedGroups > 0 else {
            print("selftest: no multi-track artist groups to check")
            return false
        }
        print("selftest: \(checkedGroups) artist groups ordered album → disc → track (\(checkedTracks) tracks)")
        return true
    }

    /// Clicking the `#` column must produce the same chain, flattened.
    private static func checkColumnSort(_ store: LibraryStore) -> Bool {
        store.toggleSort(.trackNumber)
        defer { store.toggleSort(.trackNumber); store.toggleSort(.trackNumber) }
        guard store.sortColumn == .trackNumber, store.sortAscending else {
            print("selftest: sort did not engage")
            return false
        }
        let flat = store.rows.compactMap { row -> Track? in
            if case .track(let track, _) = row { return track }
            return nil
        }
        guard flat.count == store.filteredTracks.count else {
            print("selftest: sorted rows are not flat (\(flat.count) vs \(store.filteredTracks.count))")
            return false
        }
        for i in 1..<flat.count where !libraryOrdered(flat[i - 1], flat[i]) {
            print("selftest: column sort broken at \(i): \(describe(flat[i - 1])) → \(describe(flat[i]))")
            return false
        }
        print("selftest: # column sorted artist → album → disc → track over \(flat.count) tracks")
        print("selftest: first 3 — \(flat.prefix(3).map(describe).joined(separator: " | "))")
        return true
    }

    /// Real files rarely have multi-disc albums, so the disc level is exercised
    /// against a synthetic album instead of waiting for the right CD box set.
    private static func checkDiscOrder() -> Bool {
        let store = makeStore()
        func make(_ title: String, _ disc: Int, _ track: Int, album: String = "Box Set") -> Track {
            Track(title: title, artist: "Aimer", albumArtist: "Aimer", album: album,
                  trackNumber: track, discNumber: disc)
        }
        store.tracks = [
            make("L2", 2, 2), make("L1", 1, 2), make("R1", 1, 1, album: "Another"),
            make("L3", 2, 1), make("L0", 1, 1)
        ]
        store.selectedSection = .library
        store.viewMode = .playlist
        let order = store.allVisibleTracks.map { "\($0.album)-\($0.discNumber)-\($0.trackNumber)" }
        let want = ["Another-1-1", "Box Set-1-1", "Box Set-1-2", "Box Set-2-1", "Box Set-2-2"]
        guard order == want else {
            print("selftest: disc order wrong: \(order) want \(want)")
            return false
        }
        print("selftest: multi-disc album ordered disc → track (\(order.joined(separator: " ")))")
        return true
    }

    private static func libraryOrdered(_ a: Track, _ b: Track) -> Bool {
        let artistA = LibraryStore.libraryArtist(a), artistB = LibraryStore.libraryArtist(b)
        if artistA != artistB {
            return artistA.localizedStandardCompare(artistB) != .orderedDescending
        }
        let album = a.album.localizedStandardCompare(b.album)
        if album != .orderedSame { return album == .orderedAscending }
        if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
        if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
        return a.title.localizedStandardCompare(b.title) != .orderedDescending
    }

    private static func describe(_ t: Track) -> String {
        "\(LibraryStore.libraryArtist(t)) / \(t.album) / d\(t.discNumber)t\(t.trackNumber) \(t.title)"
    }

    // MARK: - Play modes

    /// 顺序 stops at the end, 列表循环 wraps, 单曲循环 repeats, 随机 picks another.
    /// The analyser must put a tone in the band that matches its frequency —
    /// this is what separates a real FFT meter from a decorative animation.
    private static func checkSpectrum() -> Bool {
        let sampleRate = 44_100.0
        func tone(_ frequency: Double, amplitude: Float = 0.8) -> [Float] {
            (0..<SpectrumAnalyzer.fftSize).map { index in
                amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
            }
        }

        func peakBand(of samples: [Float]) -> (band: Int, values: [CGFloat]) {
            let values = SpectrumAnalyzer.instants(of: samples, sampleRate: sampleRate)
            var best = 0
            for index in values.indices where values[index] > values[best] { best = index }
            return (best, values)
        }

        let low = peakBand(of: tone(440))
        let high = peakBand(of: tone(6_000))
        let silent = SpectrumAnalyzer.instants(of: Array(repeating: 0, count: SpectrumAnalyzer.fftSize),
                                               sampleRate: sampleRate)

        let lowTarget = SpectrumAnalyzer.centreFrequency(of: low.band, sampleRate: sampleRate)
        let highTarget = SpectrumAnalyzer.centreFrequency(of: high.band, sampleRate: sampleRate)
        // Log bands are ~13% wide, so a correct mapping lands within a band of
        // the true frequency; anything wilder means the bins are misaligned.
        let lowOk = lowTarget > 440 / 1.25 && lowTarget < 440 * 1.25
        let highOk = highTarget > 6_000 / 1.25 && highTarget < 6_000 * 1.25
        let orderedOk = high.band > low.band
        let silentOk = silent.allSatisfy { $0 < 0.02 }
        let levelOk = low.values[low.band] > 0.4 && low.values[low.band] <= 1

        NSLog("selftest: spectrum — 440Hz→band %d (%.0fHz), 6kHz→band %d (%.0fHz), silent=%@",
              low.band, lowTarget, high.band, highTarget, silentOk ? "flat" : "NOT flat")
        return lowOk && highOk && orderedOk && silentOk && levelOk
    }

    /// The chrome must follow the cover: a cool cover cools it, a warm one warms
    /// it, and a missing cover leaves the measured reference palette untouched.
    /// Two albums that share a name but not an artist must still produce unique
    /// row ids — a duplicate `ForEach` id is a layout bug that only shows up with
    /// a compilation in the library.
    private static func checkRowIDs() -> Bool {
        // A compilation: same album, same album artist, two different artists.
        // In the artist view the two tracks land in two groups that share one
        // albumKey, which is exactly the case where `"album:" + albumKey` used to
        // collide. Keying off `AlbumGroup.id` is what makes this pass.
        var one = Track(title: "Same", artist: "A", albumArtist: "Various", album: "Shared", url: nil)
        var two = Track(title: "Other", artist: "B", albumArtist: "Various", album: "Shared", url: nil)
        one.trackNumber = 1
        two.trackNumber = 1
        let store = makeStore()
        store.replaceTracksForTesting([one, two])
        store.viewMode = .artists
        let ids = store.rows.map(\.id)
        // Two groups, each a header plus one track — four rows, four unique ids.
        let unique = ids.count == 4 && Set(ids).count == ids.count
        NSLog("selftest: row ids — %d rows, %d unique, %@", ids.count, Set(ids).count, ids.joined(separator: " | "))
        return unique
    }

    /// Covers decode off the main thread, so the first palette request for an
    /// album arrives empty. The controller must not cache that miss: once the
    /// bitmap lands the chrome has to move to the cover's colours.
    private static func checkPaletteAsyncArrival() -> Bool {
        let theme = ThemeController()
        theme.adopt(artwork: nil, albumKey: "late-cover")
        let before = theme.palette
        guard let warm = solidImage(red: 0.92, green: 0.28, blue: 0.36) else { return false }
        theme.adopt(artwork: warm, albumKey: "late-cover")
        let after = theme.palette
        let expected = Palette.derive(from: warm)
        let ok = before == .reference && after == expected
        NSLog("selftest: palette late arrival — before=reference:%@ after=derived:%@",
              String(before == .reference), String(after == expected))
        return ok
    }

    /// A playlist has to survive a quit, and it is stored by track id, so the
    /// round trip has to keep both the list and its membership.
    private static func checkPlaylistRoundTrip(_ store: LibraryStore) -> Bool {
        let members = Array(store.allVisibleTracks.prefix(2)).map(\.id)
        guard members.count == 2 else { return false }
        let playlist = store.addPlaylist()
        for id in members { store.addToPlaylist(id, playlistID: playlist.id) }
        store.flushSnapshot()
        guard let saved = store.cache.load(), let restored = saved.playlists,
              let match = restored.first(where: { $0.id == playlist.id }) else {
            NSLog("selftest: playlist did not reach the snapshot")
            return false
        }
        let ok = Set(match.trackIDs) == Set(members)
        store.removePlaylist(playlist.id)
        NSLog("selftest: playlist round trip — %d members, restored=%@", members.count, String(ok))
        return ok
    }

    private static func checkPalette() -> Bool {
        guard Palette.derive(from: nil) == Palette.reference else {
            NSLog("selftest: no artwork did not fall back to the reference palette")
            return false
        }

        func components(_ color: Color) -> (red: Double, green: Double, blue: Double) {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }

        guard let cool = solidImage(red: 0.10, green: 0.28, blue: 0.72),
              let warm = solidImage(red: 0.92, green: 0.28, blue: 0.36) else { return false }

        let coolSurface = components(Palette.derive(from: cool).windowBG)
        let warmSurface = components(Palette.derive(from: warm).windowBG)
        let coolIsBlue = coolSurface.blue > coolSurface.red + 0.05
        let warmIsRed = warmSurface.red > warmSurface.blue + 0.02
        NSLog("selftest: palette — cool=(%.2f %.2f %.2f) warm=(%.2f %.2f %.2f)",
              coolSurface.red, coolSurface.green, coolSurface.blue,
              warmSurface.red, warmSurface.green, warmSurface.blue)
        return coolIsBlue && warmIsRed
    }

    private static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(colorSpace: space, components: [red, green, blue, 1]) ?? CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let cg = context.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 8, height: 8))
    }

    /// Closing the app must leave a usable snapshot behind; the user's real
    /// snapshot is put back afterwards.
    private static func checkPlaybackMemory() -> Bool {
        let original = PlaybackMemory.load()
        defer {
            if let original { PlaybackMemory.save(original) } else { PlaybackMemory.clear() }
        }

        let sample = PlaybackSnapshot(filePath: "/tmp/self-test.m4a", album: "Self Test",
                                      albumArtist: "Tester", title: "Round Trip",
                                      trackNumber: 7, position: 42.5, volume: 0.5,
                                      playMode: PlayMode.repeatOne.rawValue, savedAt: Date())
        PlaybackMemory.save(sample)
        guard let loaded = PlaybackMemory.load() else { return false }
        let ok = loaded.title == "Round Trip"
            && loaded.position == 42.5
            && loaded.playMode == PlayMode.repeatOne.rawValue
            && loaded.trackNumber == 7
        NSLog("selftest: playback memory round-trip %@ (%.1fs)", ok ? "ok" : "FAILED", loaded.position)
        return ok
    }

    private static func checkPlayModes() -> Bool {
        func track(_ title: String, _ number: Int) -> Track {
            Track(title: title, artist: "T", albumArtist: "T", album: "Demo",
                  trackNumber: number, duration: 30)
        }
        let a = track("A", 1), b = track("B", 2), c = track("C", 3)
        let list = [a, b, c]
        let player = PlayerEngine()
        defer { player.stop() }

        player.playMode = .sequential
        player.play(c, in: list)
        player.next()
        let sequentialStops = player.currentTrack?.title == "C" && !player.isPlaying

        player.playMode = .repeatAll
        player.play(c, in: list)
        player.next()
        let repeatAllWraps = player.currentTrack?.title == "A" && player.isPlaying

        player.playMode = .repeatOne
        player.play(b, in: list)
        player.next()
        let repeatOneRepeats = player.currentTrack?.title == "B" && player.isPlaying

        player.playMode = .shuffle
        player.play(a, in: list)
        player.next()
        let shuffleMoves = player.currentTrack?.title != "A" && player.isPlaying

        // Cycling walks all four modes and comes back around.
        player.playMode = .sequential
        for _ in 0..<PlayMode.allCases.count { player.cyclePlayMode() }
        let cycleWraps = player.playMode == .sequential

        // The path a track takes when it actually runs out — this is the one the
        // user sees, and it used to be gated on "the integer second changed".
        player.playMode = .sequential
        player.play(a, in: list)
        player.handleTrackEnd()
        let endAdvances = player.currentTrack?.title == "B" && player.isPlaying
        player.handleTrackEnd()
        let endAdvancesAgain = player.currentTrack?.title == "C" && player.isPlaying
        player.handleTrackEnd()
        let endStopsAtLast = player.currentTrack?.title == "C" && !player.isPlaying

        print("selftest: modes — 顺序停=\(sequentialStops), 列表循环回绕=\(repeatAllWraps), 单曲循环=\(repeatOneRepeats), 随机换=\(shuffleMoves), 循环切换=\(cycleWraps), 播完续播=\(endAdvances), 连续续播=\(endAdvancesAgain), 末尾停=\(endStopsAtLast)")
        return sequentialStops && repeatAllWraps && repeatOneRepeats && shuffleMoves && cycleWraps
            && endAdvances && endAdvancesAgain && endStopsAtLast
    }

    // MARK: - Run-loop plumbing

    private static func wait(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func wait(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
