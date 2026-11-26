import AppKit
import Combine
import UserNotifications

/// Posts a system banner when the track changes.
///
/// Two things are easy to get wrong here:
///
/// * `UNUserNotificationCenter.current()` throws in a process without a bundle
///   identifier, and the self-test / render tools run from `.build/debug/MusicApp`
///   — so everything degrades to a no-op when `Bundle.main.bundleIdentifier` is
///   nil instead of crashing the tool.
/// * macOS only shows a banner for the *active* app if the centre's delegate says
///   so, and the centre takes its delegate before the app finishes launching —
///   setting it from a view's `.task` is already too late. `NotificationBridge`
///   is that delegate, installed from the app delegate.
@MainActor
final class NowPlayingNotifier {
    /// Notification Centre keeps exactly one card: the track that is playing now.
    ///
    /// Each post gets its **own** identifier. A fixed one would be re-added as an
    /// *update* of the card already delivered, and macOS then presents nothing in
    /// the foreground — the banner would silently stop appearing. So the previous
    /// card is removed by its identifier and the new one added under a fresh id;
    /// presentation never depends on a remove-then-add ordering. The one-off clear
    /// in `attach()` drops whatever an earlier launch (or a crash mid-post) left.
    static let identifierPrefix = "now-playing"

    /// `false` for a bare SwiftPM binary; see the note above.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Holding ⌘→ for three tracks should leave one banner behind, not three —
    /// the post is deferred until the selection settles.
    private static let settleDelay: Duration = .milliseconds(220)

    private let player: PlayerEngine
    private let artwork: (Track) -> NSImage?
    private let isEnabled: () -> Bool
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackID: UUID?
    private var pending: Task<Void, Never>?
    /// Serial for the per-post identifier; see `identifierPrefix`.
    private var postSerial = 0
    /// The card the next post replaces.
    private var lastPostedIdentifier: String?
    /// Guards `attach()` against a second live subscription; see `detach`.
    private var installed = false
    /// Test seam: when set, a post reports here instead of touching the
    /// notification centre, so the self-test can drive `schedule` without a
    /// bundle id or a real banner. Nil in the app.
    var onAnnounce: ((Track) -> Void)?

    init(player: PlayerEngine,
         isEnabled: @escaping () -> Bool = { true },
         artwork: @escaping (Track) -> NSImage?) {
        self.player = player
        self.isEnabled = isEnabled
        self.artwork = artwork
    }

    /// Starts watching the player. Permission and the delegate belong to
    /// `NotificationBridge`, which runs at launch. Safe to call more than once.
    func attach() {
        // Idempotent, like `MediaCenter.attach`: a second live subscription would
        // double the sink, and the two would cancel each other's pending banner.
        guard !installed else { return }
        guard Self.isAvailable else {
            NSLog("音乐: notifications need a bundled app; skipping (no bundle id)")
            return
        }
        installed = true

        // Clear anything an earlier launch (or a crash mid-post) left in Centre;
        // this app posts nothing but the now-playing card. Done once here rather
        // than on every post, so `post` never races a clear against its own add.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        lastPostedIdentifier = nil

        player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                // `receive(on: RunLoop.main)` delivers on the main thread, after
                // `PlayerEngine.start()` has flipped `isPlaying`.
                MainActor.assumeIsolated { self?.schedule(track) }
            }
            .store(in: &cancellables)
    }

    func detach() {
        pending?.cancel()
        pending = nil
        cancellables.removeAll()
        installed = false
    }

    // MARK: - Posting

    /// Waits for the selection to stop moving, then posts once. Internal rather
    /// than private so the self-test can drive the debounce directly — `attach()`
    /// bails without a bundle id, so it cannot reach this from a test binary.
    func schedule(_ track: Track?) {
        guard let track else {
            pending?.cancel()
            pending = nil
            lastTrackID = nil
            return
        }
        // A repeat of the current track must not cancel the banner already queued
        // for it — so the dedupe guard runs *before* the cancel, not after.
        guard track.id != lastTrackID else { return }
        lastTrackID = track.id

        // Paused or stopped: nothing to announce. This — not a "first track"
        // flag — is what keeps a restored session silent: `restore()` sets
        // `currentTrack` but leaves `isPlaying` false, so the deferred delivery
        // arrives while paused. A track the user actually starts arrives with
        // `isPlaying` already true, because `start()` flips it before
        // `receive(on:)` delivers — so an empty launch's first play banners too.
        guard player.isPlaying else {
            pending?.cancel()
            pending = nil
            return
        }

        pending?.cancel()
        pending = nil
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.post(track)
        }
    }

    private func post(_ track: Track) {
        guard isEnabled(), player.isPlaying else { return }
        if let onAnnounce {
            onAnnounce(track)
            return
        }
        let content = Self.content(for: track, artwork: artwork(track))
        postSerial += 1
        let identifier = "\(Self.identifierPrefix).\(postSerial)"
        let request = UNNotificationRequest(identifier: identifier,
                                           content: content, trigger: nil)
        let centre = UNUserNotificationCenter.current()
        // Replace the card this post supersedes. The new request already has a
        // fresh id, so it presents even while this removal is still in flight.
        if let previous = lastPostedIdentifier {
            centre.removeDeliveredNotifications(withIdentifiers: [previous])
        }
        lastPostedIdentifier = identifier
        centre.add(request) { error in
            if let error {
                NSLog("音乐: notification failed – \(error.localizedDescription)")
            }
        }
    }

    /// The banner's payload. Built separately from the delivery so the self-test
    /// can assert on it without touching the notification centre.
    ///
    /// Two text lines is the whole design: the song on top, then
    /// `artist — album` underneath. `body` stays empty — on macOS it would add a
    /// third, dimmer line and the reference has exactly two.
    static func content(for track: Track, artwork: NSImage?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = track.title
        content.subtitle = secondaryLine(artist: track.artist, album: track.album)
        content.threadIdentifier = "now-playing"
        if let artwork, let url = write(attachmentImage(artwork)) {
            content.attachments = [try? UNNotificationAttachment(identifier: "cover", url: url)]
                .compactMap { $0 }
        }
        return content
    }

    /// `artist — album`, dropping either half when it is blank so a library with
    /// missing tags never shows a dangling dash.
    ///
    /// The banner grows a row when the second line wraps, which breaks the
    /// two-line shape; a long line is trimmed to keep it. Measured in *cells*,
    /// not characters: a CJK glyph is about twice as wide as a Latin one (so a
    /// 20-glyph Japanese line and a 40-letter English one are both ~40 cells).
    ///
    /// 28 is calibrated to the *narrow* end of the banner's text area: a 40-cell
    /// all-ASCII line such as `ASIAN KUNG-FU GENERATION — Wonder Future` slipped
    /// under the old 44-cell budget and still wrapped onto a third row, so 44 was
    /// ~1.5× too generous. 28 keeps the two-line shape at the font sizes in use.
    static let secondaryLineLimit = 28

    static func cellWidth(of text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { total, scalar in
            total += isWide(scalar) ? 2 : 1
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF:
            return true
        default:
            return false
        }
    }

    static func secondaryLine(artist: String, album: String) -> String {
        let parts = [artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = parts.joined(separator: " — ")
        guard cellWidth(of: joined) > secondaryLineLimit else { return joined }

        // Keep `artist — album` when the artist still fits: trim the album, not
        // the whole line, so a long album does not turn into a dangling dash.
        let artistPart = parts.count == 2 ? parts[0] + " — " : ""
        let artistCells = cellWidth(of: artistPart)
        let albumRoom = secondaryLineLimit - 2 - artistCells
        if parts.count == 2, albumRoom >= 6 {
            let album = truncate(parts[1], to: albumRoom)
            return artistPart + album + "…"
        }
        return truncate(joined, to: secondaryLineLimit - 2) + "…"
    }

    /// Cuts `text` to at most `cells` display cells, never leaving a separator or
    /// a stray space at the end (「ASIAN KUNG-FU GENERATION —…」 reads as a typo).
    private static func truncate(_ text: String, to cells: Int) -> String {
        var kept = ""
        var used = 0
        for character in text {
            let width = cellWidth(of: String(character))
            if used + width > cells { break }
            kept.append(character)
            used += width
        }
        let separators = CharacterSet(charactersIn: " \u{2014}\u{2013}-–")
        while let last = kept.unicodeScalars.last, separators.contains(last) {
            kept.unicodeScalars.removeLast()
        }
        return kept
    }

    /// The banner's artwork slot is ~40 pt wide; a 160 px square is already more
    /// than the display can use, and it keeps the temp file tiny.
    static let attachmentPixel: CGFloat = 160

    /// `UNNotificationAttachment` wants a file, not an `NSImage`. Downscaling
    /// first matters: the caller may hand over the full 768 px cover, and a
    /// banner-sized thumbnail is a few kilobytes instead of a megabyte.
    private static func attachmentImage(_ image: NSImage) -> NSImage? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, attachmentPixel / max(source.width, source.height))
        let target = NSSize(width: max(1, (source.width * scale).rounded()),
                            height: max(1, (source.height * scale).rounded()))
        // `lockFocus` is deprecated; `drawingHandler` draws at the image's own
        // 1× size, so the PNG on disk is `target` pixels, not 2× that on a
        // Retina display.
        return NSImage(size: target, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }

    private static func write(_ image: NSImage?) -> URL? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-now-playing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir)
        let url = dir.appendingPathComponent("cover-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Keeps the newest few covers; the daemon has already copied what it needs.
    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted { a, b in
            let left = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left > right
        }
        for old in sorted.dropFirst(4) { try? fm.removeItem(at: old) }
    }
}

extension NowPlayingNotifier {
    /// `--notify-count`: prints what is sitting in Notification Centre and exits.
    /// Used to prove that skipping through tracks leaves a single card.
    static func printDelivered() -> Never {
        guard isAvailable else {
            print("notify: no bundle id; nothing is delivered")
            exit(1)
        }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            print("notify: delivered=\(delivered.count) titles=\(delivered.map(\.request.content.title))")
            exit(0)
        }
        dispatchMain()
    }

    /// `--notify-test`: asks the system what it thinks of us and posts one banner.
    /// Used to tell "our request was rejected" apart from "our request was never
    /// made" while the feature is being wired up.
    static func runDiagnostics() -> Never {
        guard isAvailable else {
            print("notify: no bundle id; notifications are unavailable")
            exit(1)
        }
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            print("notify: authorization=\(settings.authorizationStatus.rawValue) alertStyle=\(settings.alertStyle.rawValue) sound=\(settings.soundSetting.rawValue)")
            func banner(_ title: String, _ subtitle: String) -> UNMutableNotificationContent {
                let content = UNMutableNotificationContent()
                content.title = title
                content.subtitle = subtitle
                return content
            }
            // Distinct identifiers, like the real posts: the second would be
            // swallowed as an update if it reused the first's id.
            let firstID = "\(Self.identifierPrefix).diag-1"
            let secondID = "\(Self.identifierPrefix).diag-2"
            centre.removeAllDeliveredNotifications()
            centre.add(UNNotificationRequest(identifier: firstID,
                                             content: banner("通知自检", "歌手 — 专辑"),
                                             trigger: nil)) { error in
                print("notify: add \(error == nil ? "ok" : "failed – \(error?.localizedDescription ?? "unknown")")")
                // Remove the first by id; the second keeps its own, so exactly one
                // card is left regardless of when the removal lands.
                centre.removeDeliveredNotifications(withIdentifiers: [firstID])
                centre.add(UNNotificationRequest(identifier: secondID,
                                                 content: banner("通知自检 2", "只应留下这一条"),
                                                 trigger: nil)) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        centre.getDeliveredNotifications { delivered in
                            print("notify: delivered=\(delivered.count) titles=\(delivered.map(\.request.content.title))")
                            exit(delivered.count == 1 ? 0 : 2)
                        }
                    }
                }
            }
        }
        dispatchMain()
    }
}

/// The notification centre's delegate, installed before launch finishes.
///
/// It exists separately from `NowPlayingNotifier` because the centre has to own a
/// delegate from the very start, while the notifier needs the player — and the
/// delegate's only job is the presentation policy: a banner even while our window
/// is frontmost, which is exactly when someone hits ⌘→ to try the feature.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()

    /// Asks for permission once and takes the delegate slot. A no-op without a
    /// bundle id (`UNUserNotificationCenter.current()` throws there).
    func install() {
        guard NowPlayingNotifier.isAvailable else { return }
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                NSLog("音乐: notification permission failed – \(error.localizedDescription)")
            } else if !granted {
                NSLog("音乐: notifications are off for this app")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
