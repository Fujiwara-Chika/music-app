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
    /// Requests are identified per track: re-adding one with an identifier that is
    /// already delivered is treated as an *update*, and macOS then presents nothing
    /// in the foreground. The previous one is removed so Centre keeps a single card.
    private var lastRequestID: String?

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
    /// The first track after launch is the state the app opens in, not a *change*
    /// — no banner for it.
    private var primed = false

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
        guard Self.isAvailable else {
            NSLog("音乐: notifications need a bundled app; skipping (no bundle id)")
            return
        }
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
    }

    // MARK: - Posting

    /// Waits for the selection to stop moving, then posts once.
    private func schedule(_ track: Track?) {
        pending?.cancel()
        pending = nil
        guard let track else {
            lastTrackID = nil
            return
        }
        guard track.id != lastTrackID else { return }
        lastTrackID = track.id

        // The first track is the state the app opens in — a restored session, or
        // the one `--autoplay` starts — not a *change*. Priming here rather than
        // after the `isPlaying` test matters: `start()` publishes the track just
        // before it flips `isPlaying`, so a prime behind that guard would be
        // consumed by the first real skip instead.
        guard primed else {
            primed = true
            return
        }
        // Paused or stopped: nothing to announce.
        guard player.isPlaying else { return }

        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.post(track)
        }
    }

    private func post(_ track: Track) {
        guard isEnabled(), player.isPlaying else { return }
        let content = Self.content(for: track, artwork: artwork(track))
        let requestID = "now-playing.\(track.id.uuidString)"
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        let centre = UNUserNotificationCenter.current()
        if let lastRequestID {
            centre.removeDeliveredNotifications(withIdentifiers: [lastRequestID])
        }
        lastRequestID = requestID
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
    /// two-line shape; a long album name is trimmed to keep it.
    /// Measured in *cells*, not characters: a CJK glyph is about twice as wide as
    /// a Latin one, so counting characters lets 「ずっと真夜中でいいのに。 — …」
    /// wrap into a third row while 44 Latin letters would still fit.
    static let secondaryLineLimit = 44

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

        // Leave room for the ellipsis itself (two cells).
        var trimmed = ""
        var cells = 0
        for character in joined {
            let width = cellWidth(of: String(character))
            if cells + width > secondaryLineLimit - 2 { break }
            trimmed.append(character)
            cells += width
        }
        return trimmed.trimmingCharacters(in: .whitespaces) + "…"
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
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
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
            let content = UNMutableNotificationContent()
            content.title = "通知自检"
            content.subtitle = "歌手 — 专辑"
            let request = UNNotificationRequest(identifier: "notify-self-check", content: content, trigger: nil)
            centre.add(request) { error in
                print("notify: add \(error == nil ? "ok" : "failed – \(error!.localizedDescription)")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
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
