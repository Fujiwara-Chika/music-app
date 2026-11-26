import AppKit
import CryptoKit

/// The result of one folder scan, persisted so the app can open instantly
/// instead of walking the disk every launch (5,800 files ≈ 13s).
///
/// Tracks carry their `playCount` / `rating` too, so those survive a relaunch as
/// long as the file still has the same path.
struct LibrarySnapshot: Codable {
    var version: Int = SnapshotWriter.version
    var folderPath: String
    var savedAt: Date
    var tracks: [Track]
    /// Optional so snapshots written before playlists existed still decode;
    /// a plain default value would not help, because synthesised `Decodable`
    /// throws on a missing key.
    var playlists: [Playlist]?
    /// `url.path → track id`. Keeps a track's identity stable across scans that
    /// do not see the file (an emptied folder, a temporarily unmounted disk), so
    /// playlist membership comes back when the file does.
    var trackIDsByPath: [String: UUID]?
}

/// The only thing that writes the library cache.
///
/// Four code paths used to write the snapshot on their own thread (end of a
/// scan, the debounced save, the flush on quit, the empty-scan save). Serial
/// queues make each file's writes deterministic — `library.json` on one, the
/// regenerable cover JPEGs on another so they can never hold up a quit — keep the
/// JSON and JPEG encoding off the main thread, and let the self-test point at a
/// scratch directory without a mutable global.
final class SnapshotWriter {
    /// Bumped when the parser learns to read something a cached snapshot may have
    /// got wrong. v2: `trkn` / `disk` are binary atoms — v1 caches saved every
    /// multi-disc album as "disc 1, track 1", so they must be re-read.
    static let version = 2

    /// ~/Library/Application Support/local.aria.music
    ///
    /// `MUSIC_CACHE_DIR` redirects it so a benchmark or screenshot run can scan a
    /// real folder without touching the user's library snapshot.
    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MUSIC_CACHE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("local.aria.music", isDirectory: true)
    }

    let directory: URL

    /// Two queues on purpose. `library.json` must stay ordered, but a cover is
    /// regenerable: encoding ~1,000 JPEGs on the same queue as the snapshot meant
    /// quitting (or removing the library) could wait seconds behind them, because
    /// `flush`/`clear` are synchronous. Split, quitting only waits for the JSON.
    private let snapshotQueue = DispatchQueue(label: "local.aria.music.snapshot", qos: .utility)
    private let artworkQueue = DispatchQueue(label: "local.aria.music.artwork", qos: .utility)

    init(directory: URL = SnapshotWriter.defaultDirectory) {
        self.directory = directory
    }

    var snapshotURL: URL { directory.appendingPathComponent("library.json") }
    var artworkDirectory: URL { directory.appendingPathComponent("artwork", isDirectory: true) }

    // MARK: - Snapshot

    /// Synchronous because the app reads it once, on launch, before the window
    /// appears — and a warm start has to beat the 13s scan it replaces.
    /// Older snapshots are accepted on purpose: every field added since v1 is
    /// optional, so a v1 file still decodes with its play counts, ratings and
    /// playlists intact. Rejecting it would silently reset a user who upgrades —
    /// the caller re-scans afterwards to re-parse the tags v2 fixed.
    func load() -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data),
              snapshot.version <= Self.version else { return nil }
        return snapshot
    }

    /// Queues the snapshot (and any covers that came with it) and returns
    /// immediately. `completion` runs after the snapshot is on disk — it does not
    /// wait for the covers, which are regenerable.
    func write(_ snapshot: LibrarySnapshot,
               artworks: [String: NSImage] = [:],
               replacingArtwork: Bool = false,
               completion: (() -> Void)? = nil) {
        snapshotQueue.async { [self] in
            writeSnapshotNow(snapshot)
            completion?()
        }
        writeArtworks(artworks, replacing: replacingArtwork)
    }

    /// Blocking write of the snapshot, for the quit path: the debounced write
    /// would be dropped otherwise, losing a playlist or a rating made in the last
    /// two seconds. Covers are queued, not awaited — killing the process in the
    /// middle of a JPEG encode only costs a re-extractable cover.
    func flush(_ snapshot: LibrarySnapshot,
               artworks: [String: NSImage] = [:],
               replacingArtwork: Bool = false) {
        snapshotQueue.sync { writeSnapshotNow(snapshot) }
        writeArtworks(artworks, replacing: replacingArtwork)
    }

    /// Blocks until the snapshot queue is empty. Tests use it as a barrier;
    /// production code relies on `flush` instead.
    func drainSnapshots() {
        snapshotQueue.sync {}
    }

    /// Blocks until the cover queue is empty too.
    func drainArtwork() {
        artworkQueue.sync {}
    }

    /// Runs `work` on the cover queue, after everything already queued there.
    /// Only the self-test calls this: it is how `ordering` gates the queue and
    /// observes "this cover batch finished" without looking at the files (a
    /// cover may legitimately land while `flush` is still running).
    func enqueueArtworkForTesting(_ work: @escaping () -> Void) {
        artworkQueue.async(execute: work)
    }

    private func writeSnapshotNow(_ snapshot: LibrarySnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            NSLog("音乐: library cache write failed – \(error.localizedDescription)")
        }
    }

    private func writeArtworks(_ artworks: [String: NSImage], replacing: Bool) {
        guard !artworks.isEmpty else { return }
        artworkQueue.async { [self] in
            try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            for (key, image) in artworks {
                let url = artworkURL(for: key)
                if !replacing, FileManager.default.fileExists(atPath: url.path) { continue }
                guard let jpeg = Self.jpegData(from: image) else { continue }
                try? jpeg.write(to: url, options: .atomic)
            }
        }
    }

    /// Fires and forgets, for the on-demand cover upgrade path.
    func writeArtwork(_ image: NSImage, for albumKey: String) {
        artworkQueue.async { [self] in
            try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            guard let jpeg = Self.jpegData(from: image) else { return }
            try? jpeg.write(to: artworkURL(for: albumKey), options: .atomic)
        }
    }

    /// The snapshot goes away before the call returns (removing the library must
    /// not race the next launch), the covers are wiped behind the queue so the
    /// (slow) JPEG encodes already in flight finish first and are then deleted.
    func clear() {
        snapshotQueue.sync {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        artworkQueue.async { [self] in
            try? FileManager.default.removeItem(at: artworkDirectory)
        }
    }

    // MARK: - Artwork

    /// Covers live beside the snapshot, one file per album, keyed by a digest of
    /// the album key: a single JSON blob with ~1,000 images inside would be 40MB
    /// that always has to be decoded at launch.
    func artworkURL(for albumKey: String) -> URL {
        let digest = SHA256.hash(data: Data(albumKey.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return artworkDirectory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    /// Decodes a cover straight to the size the caller will draw it at.
    ///
    /// The cache keeps 768px JPEGs so the panel stays sharp, but a 62pt table
    /// thumbnail drawn from a 768px bitmap means every visible album header costs
    /// a 2.36 MB decode plus a per-frame 6× downscale on the GPU. ImageIO can
    /// decode JPEG straight to a small bitmap, which is both cheaper and sharper
    /// than letting Core Animation do it.
    func readArtwork(for albumKey: String, maxPixel: Int) -> NSImage? {
        let url = artworkURL(for: albumKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.thumbnail(from: data, maxPixel: maxPixel)
    }

    /// `nil` when the bytes are not a decodable image.
    static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB), cg.colorSpace?.name != srgb.name,
           let converted = cg.copy(colorSpace: srgb) {
            cg = converted
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func readArtwork(for albumKey: String) -> NSImage? {
        let url = artworkURL(for: albumKey)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        // Decode eagerly at display size: `NSImage(data:)` is lazy, and a lazy
        // image can fail to rasterise when the caller has no window (the
        // offscreen renderer) even though the bytes are perfectly good.
        // Force the decode so every caller gets a bitmap-backed image.
        var rect = CGRect(origin: .zero, size: image.size)
        guard var cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        // Normalise to sRGB: covers come out of the audio files in whatever
        // profile the encoder used, and `ImageRenderer` silently skips bitmaps
        // it cannot convert (they end up as blank placeholders).
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB), cg.colorSpace?.name != srgb.name,
           let converted = cg.copy(colorSpace: srgb) {
            cg = converted
        }
        return NSImage(cgImage: cg, size: rect.size)
    }

    /// Longest side we keep for a cover. The panel draws artwork at 249pt
    /// (≈500px on a 2× display); the old 512 cap had no headroom at all, which is
    /// why covers looked soft. 768 is a 1.5× margin at roughly half the bytes of
    /// 1024 — sharp on a 2× display without a 250 MB cache for 1,000 albums.
    static let maxArtworkSide: CGFloat = 768

    /// Longest side of the cover already on disk. Reads only the file header —
    /// `NSImage` decodes lazily, so this is cheap enough for the upgrade pass.
    func artworkPixelSide(for albumKey: String) -> Int? {
        guard let image = NSImage(contentsOf: artworkURL(for: albumKey)) else { return nil }
        return Int(max(image.size.width, image.size.height).rounded())
    }

    /// Encodes one cover for the on-disk cache.
    static func jpegData(from image: NSImage) -> Data? {
        let maxSide = maxArtworkSide
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(target.width),
                                        pixelsHigh: Int(target.height),
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90])
    }
}
