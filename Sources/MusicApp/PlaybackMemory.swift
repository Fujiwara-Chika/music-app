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
    private static let storageKey = "player.resume.snapshot"

    static func load() -> PlaybackSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackSnapshot.self, from: data)
    }

    static func save(_ snapshot: PlaybackSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
