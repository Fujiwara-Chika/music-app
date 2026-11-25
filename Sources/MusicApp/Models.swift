import Foundation
import AppKit

// MARK: - Track

struct Track: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String = ""
    var trackNumber: Int = 0
    var discNumber: Int = 1
    var year: Int = 0
    var duration: TimeInterval = 0
    /// nil for the bundled demo library (no audio on disk).
    var url: URL? = nil
    /// Fingerprint of the file the tags were read from. A rescan compares these
    /// against the disk and reuses the parsed tags when nothing changed — reading
    /// 5,800 files' metadata is the slow part of a scan (13-17s), and most of it
    /// is spent on files that did not move.
    var fileMtime: Date? = nil
    var fileSize: Int64? = nil

    // Technical description, shown as "AAC | LC | 258K | 1次"
    var codec: String = "AAC"
    var bitrate: Int = 256
    var profile: String = "LC"

    var playCount: Int = 0
    var rating: Int = 0
    var lastPlayed: Date? = nil

    var lyricist: String = ""
    var composer: String = ""
    var lyrics: [String] = []

    /// Stable grouping key for album headers.
    var albumKey: String { "\(album)\u{1}\(albumArtist)" }


    var formatText: String {
        var parts: [String] = [codec]
        if !profile.isEmpty { parts.append(profile) }
        if bitrate > 0 { parts.append("\(bitrate)K") }
        parts.append(playCount == 1 ? "1次" : "\(playCount)次")
        return parts.joined(separator: " | ")
    }
}

// MARK: - Album grouping

struct AlbumGroup: Identifiable {
    /// Row identity. Normally the album key, but the artist / genre views borrow
    /// an album's cover and would otherwise hand two different groups the same
    /// id (a compilation album shows up under several artists).
    var id: String
    var albumKey: String
    var album: String
    var albumArtist: String
    var artist: String
    var year: Int
    var trackCount: Int
    var tracks: [Track]

    init(id: String? = nil, albumKey: String, album: String, albumArtist: String,
         artist: String, year: Int, trackCount: Int, tracks: [Track]) {
        self.id = id ?? albumKey
        self.albumKey = albumKey
        self.album = album
        self.albumArtist = albumArtist
        self.artist = artist
        self.year = year
        self.trackCount = trackCount
        self.tracks = tracks
    }

    var yearText: String { year > 0 ? String(year) : "" }
    var countText: String { "\(trackCount)首" }
}

// MARK: - Sorting

/// Sortable columns of the song table. The "#" half of the title column sorts by
/// track number, the title half by title, mirroring what is actually displayed.
enum SortColumn: String, CaseIterable, Identifiable {
    case trackNumber, title, album, artist, albumArtist, genre

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackNumber: return "音轨编号"
        case .title:       return "标题"
        case .album:       return "专辑"
        case .artist:      return "艺术家"
        case .albumArtist: return "专辑艺术家"
        case .genre:       return "流派"
        }
    }
}

// MARK: - View modes

/// The five view tabs across the top bar. The first four change how the table
/// groups its rows, the last one is a plain play-count ranking.
enum ViewMode: String, CaseIterable, Identifiable {
    case playlist, artists, albums, genres, stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlist: return "播放列表"
        case .artists:  return "艺术家"
        case .albums:   return "专辑"
        case .genres:   return "流派"
        case .stats:    return "播放统计"
        }
    }
}

// MARK: - Sidebar

enum LibrarySection: Hashable {
    case library
    case history
    case mostPlayed

    var title: String {
        switch self {
        case .library:    return "媒体库"
        case .history:    return "历史记录"
        case .mostPlayed: return "最常播放"
        }
    }

    var systemImage: String {
        switch self {
        case .library:    return "square.on.square.dashed"
        case .history:    return "calendar"
        case .mostPlayed: return "arrow.up.to.line"
        }
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
}

// MARK: - Play mode

/// How playback advances. One button cycles through these, the way the
/// transport bar of most players works.
enum PlayMode: Int, CaseIterable, Identifiable {
    case sequential, repeatAll, repeatOne, shuffle

    static let storageKey = "player.playMode"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll:  return "列表循环"
        case .repeatOne:  return "单曲循环"
        case .shuffle:    return "随机播放"
        }
    }

    /// Toolbar glyph, drawn by `SkinIcon` so it matches the reference's line art.
    var glyph: SkinGlyph {
        switch self {
        case .sequential: return .sequential
        case .repeatAll:  return .repeatAll
        case .repeatOne:  return .repeatOne
        case .shuffle:    return .shuffle
        }
    }

    var hint: String {
        switch self {
        case .sequential: return "顺序播放：放到最后一首就停"
        case .repeatAll:  return "列表循环：放到最后一首回到第一首"
        case .repeatOne:  return "单曲循环：一直重放当前这首"
        case .shuffle:    return "随机播放：随机挑下一首"
        }
    }
}
