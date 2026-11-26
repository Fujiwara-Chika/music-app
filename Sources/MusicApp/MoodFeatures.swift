import Foundation

// MARK: - Features

/// What we measure about a track to place it on the mood map.
///
/// Sony's "12 TONE ANALYSIS" is closed, so this is our own reading of the same
/// idea: a rhythm feature (tempo) and a tonality/brightness feature (valence),
/// both computed offline from a few 20 second windows of the file.
struct MoodFeatures: Codable, Hashable {
    /// Beats per minute, 60…200 after half/double disambiguation.
    var tempo: Double
    /// -1 = dark / minor / dull … +1 = bright / major / shiny.
    var valence: Double
    /// 0…1, short-term RMS relative to a nominal 0.3 full scale.
    var energy: Double
    /// Dominant key as "C", "Am" … — shown in the tooltip, not used for channels.
    var key: String

    /// 0…1 on a log scale from 60 to 200 BPM: the horizontal axis of the map.
    /// No detectable beat (0) sits in the middle rather than at "slowest".
    var tempoPosition: Double {
        guard tempo > 0 else { return 0.5 }
        let low = 60.0, high = 200.0
        let clamped = min(max(tempo, low), high)
        return log(clamped / low) / log(high / low)
    }

    /// Where the point lands on the vertical axis, -1…+1.
    ///
    /// Raw tonality is honest but narrow: pop chroma correlates weakly with
    /// either mode, so a 5,800-track library lands in -0.08…+0.27. Stretch that
    /// band over the plane (p05 → -1, p95 → +1) or six of the eight channels sit
    /// empty and two hold 80% of the library.
    var valencePosition: Double {
        let stretched = (valence - 0.095) / 0.175
        return min(max(stretched, -1), 1)
    }
}

// MARK: - Channels

/// The eight "channels" of the mood map. The names follow the Walkman's SensMe
/// channels, but the boundaries are ours: each channel is an anchor on the
/// (tempo, valence) plane and a track goes to the nearest one, so every track
/// lands in exactly one channel.
enum MoodChannel: String, CaseIterable, Identifiable, Codable {
    case morning, daytime, evening, night, workout, relax, emotional, upbeat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morning:   return "清晨"
        case .daytime:   return "白天"
        case .evening:   return "傍晚"
        case .night:     return "深夜"
        case .workout:   return "运动"
        case .relax:     return "放松"
        case .emotional: return "抒情"
        case .upbeat:    return "欢快"
        }
    }

    var systemImage: String {
        switch self {
        case .morning:   return "sunrise"
        case .daytime:   return "sun.max"
        case .evening:   return "sunset"
        case .night:     return "moon.stars"
        case .workout:   return "figure.run"
        case .relax:     return "leaf"
        case .emotional: return "heart"
        case .upbeat:    return "party.popper"
        }
    }

    /// Anchor on the plane: x = `tempoPosition` 0…1, y = `valence` -1…+1.
    var anchor: (x: Double, y: Double) {
        switch self {
        case .morning:   return (0.18,  0.55)
        case .daytime:   return (0.50,  0.30)
        case .evening:   return (0.58, -0.05)
        case .night:     return (0.42, -0.65)
        case .workout:   return (0.88,  0.05)
        case .relax:     return (0.16, -0.10)
        case .emotional: return (0.30, -0.85)
        case .upbeat:    return (0.82,  0.70)
        }
    }

    /// Nearest anchor wins, with tempo and valence weighted equally. Distance is
    /// computed in a square-ish space so a fast-but-sad song does not get pulled
    /// into "深夜" purely by its tempo.
    static func classify(_ features: MoodFeatures) -> MoodChannel {
        let x = features.tempoPosition
        let y = features.valencePosition
        var best = MoodChannel.daytime
        var bestDistance = Double.greatestFiniteMagnitude
        for channel in allCases {
            let dx = (x - channel.anchor.x) * 1.0
            let dy = (y - channel.anchor.y) * 0.5
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = channel
            }
        }
        return best
    }
}
