import Foundation

/// What the app was doing when it was last closed: which track, how far into it,
/// plus the volume and play mode. Restored on the next launch so the window
/// comes back the way it was left.
struct PlaybackSnapshot: Codable {
    var filePath: String?
    var album: String
    var albumArtist: String
    var title: String
    var trackNumber: Int
    var position: Double
    var volume: Double
    var playMode: Int
    var savedAt: Date
}

enum PlaybackMemory {
    static let storageKey = "player.resume.snapshot"

    /// Where the session is kept. `.standard` in the app; the self test points it
    /// at a scratch suite, because that suite drives a real `PlayerEngine` whose
    /// `persistPlayback`/`stop` would otherwise replace the resume point the user
    /// is waiting for. Only a test ever reassigns this.
    static var store: UserDefaults = .standard

    static func load() -> PlaybackSnapshot? {
        guard let data = store.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackSnapshot.self, from: data)
    }

    static func save(_ snapshot: PlaybackSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store.set(data, forKey: storageKey)
    }

    static func clear() {
        store.removeObject(forKey: storageKey)
    }
}

/// Where this process keeps the session it would restore on the next launch.
///
/// Normally the app's own defaults. The screenshot scripts launch the real app
/// with `--autoplay` — which plays a track and seeks into it — and that would
/// rewrite the resume point the user is waiting for, so those runs get a
/// throwaway suite instead. `--scratch-session` is the explicit form for any
/// other script.
///
/// The value is resolved on first access, which is when `MusicAppMain` builds its
/// store and player — before either of them reads the folder or the volume.
enum LaunchSession {
    static let defaults: UserDefaults = makeDefaults()

    /// The rule on its own, so the self test can assert it without a process.
    static func needsScratchSuite(_ arguments: [String]) -> Bool {
        arguments.contains("--scratch-session") || arguments.contains("--autoplay")
    }

    private static func makeDefaults() -> UserDefaults {
        guard needsScratchSuite(CommandLine.arguments) else { return .standard }
        let suite = "local.aria.music.scratch.\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suite) else { return .standard }
        scratch.removePersistentDomain(forName: suite)
        PlaybackMemory.store = scratch
        NSLog("音乐: session writes are sandboxed (\(suite))")
        return scratch
    }
}
