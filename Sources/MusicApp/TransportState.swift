import SwiftUI
import Foundation

/// The three pieces of state that change while audio plays, split out of
/// `PlayerEngine` so that SwiftUI only re-renders the views that actually show
/// them.
///
/// `PlayerEngine` publishes rarely-changed things (current track, duration). If
/// `progress` lived there too, every view holding the engine as an
/// `@EnvironmentObject` — the whole window plus ~30 visible table rows — would be
/// rebuilt 30 times a second, which cost about 34% CPU on its own.

/// Elapsed time, updated 15×/s (the timer rate). Observed by the transport bar (seek bar + clock).
@MainActor
final class ProgressClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Spectrum bands, updated with the audio. Observed by the meter only.
@MainActor
final class SpectrumBands: ObservableObject {
    @Published var values: [CGFloat] = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
}

/// Which track is playing, and whether it is playing. Changes on play/pause/track
/// change only. Observed by the table rows (for the ▶ marker).
@MainActor
final class PlaybackCursor: ObservableObject {
    @Published var trackID: UUID?
    @Published var isPlaying: Bool = false
}

/// Bumped when a cover bitmap lands. Kept out of `LibraryStore` on purpose: the
/// store is observed by every visible row, so publishing "a thumbnail decoded"
/// there would rebuild the whole table dozens of times per scroll (each newly
/// revealed album decodes one). Only cover views subscribe to this.
@MainActor
final class ArtworkTicker: ObservableObject {
    @Published private(set) var revision = 0
    /// Per-album counters: a panel that shows one cover should not refresh when
    /// some unrelated row's thumbnail lands.
    private var perAlbum: [String: Int] = [:]

    func bump() { revision &+= 1 }

    func bump(album key: String) {
        revision &+= 1
        perAlbum[key, default: 0] &+= 1
    }

    func revision(for key: String) -> Int { perAlbum[key] ?? 0 }
}
