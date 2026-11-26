import AppKit
import Combine
import MediaPlayer

/// Hands the current track to the system (Control Center, the "now playing" card,
/// the hardware media keys) and turns those controls back into transport calls.
///
/// The system routes the media keys to whichever app most recently told it what
/// is playing, so both halves are needed: `MPNowPlayingInfoCenter` for the
/// metadata and `MPRemoteCommandCenter` for the buttons. Progress is not pushed
/// on every tick — the system extrapolates from `elapsed` + `rate`, which is what
/// keeps the panel's clock running while the app is in the background.
@MainActor
final class MediaCenter {
    /// The buttons we support. Kept apart from the command registration so the
    /// self-test can drive the mapping without installing global handlers.
    enum Action: Equatable {
        case play, pause, toggle, next, previous, stop
        case seek(TimeInterval)
    }

    private let player: PlayerEngine
    private let artwork: (Track) -> NSImage?
    private var installed = false
    private var cancellables = Set<AnyCancellable>()
    /// The handlers *this* instance registered. `removeTarget(nil)` would take out
    /// every handler in the process, which is harmless with one window and wrong
    /// as soon as there are two.
    private var targetTokens: [(command: MPRemoteCommand, token: Any)] = []
    /// How many times the card has been rebuilt. The self test uses it to prove
    /// that a volume drag does *not* touch the now-playing info.
    private(set) var refreshCount = 0

    init(player: PlayerEngine, artwork: @escaping (Track) -> NSImage?) {
        self.player = player
        self.artwork = artwork
    }

    /// Registers the remote commands and starts mirroring the player. Safe to
    /// call more than once.
    func attach() {
        guard !installed else { return }
        installed = true
        installCommands()
        observe()
        refresh()
    }

    /// Stops mirroring and drops the registration. Called when the window goes
    /// away, so a rebuilt view tree does not leave the media keys pointing at a
    /// player nobody is driving.
    func detach() {
        cancellables.removeAll()
        for entry in targetTokens { entry.command.removeTarget(entry.token) }
        targetTokens.removeAll()
        clear()
        installed = false
    }

    /// Only what the now-playing card actually shows: which track, how long it is,
    /// and whether it is playing. Subscribing to `player.objectWillChange` would
    /// also fire for `volume`, which publishes on every slider frame — and volume
    /// has nothing to do with this card.
    private func observe() {
        // `objectWillChange` lands before the value, so the refresh waits for the
        // next runloop turn.
        player.cursor.$trackID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIfOnMain() }
            .store(in: &cancellables)
        player.cursor.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIfOnMain() }
            .store(in: &cancellables)
        player.$duration
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIfOnMain() }
            .store(in: &cancellables)
    }

    // MARK: - Remote commands

    private func installCommands() {
        let centre = MPRemoteCommandCenter.shared()

        // Everything we cannot honour stays off, so Control Center shows no dead
        // buttons (skip, ratings, bookmarks, rate, shuffle/repeat modes…).
        for command in [centre.skipForwardCommand, centre.skipBackwardCommand,
                        centre.seekForwardCommand, centre.seekBackwardCommand,
                        centre.changePlaybackRateCommand, centre.ratingCommand,
                        centre.likeCommand, centre.dislikeCommand,
                        centre.bookmarkCommand] {
            command.isEnabled = false
        }

        bind(centre.playCommand, .play)
        bind(centre.pauseCommand, .pause)
        bind(centre.togglePlayPauseCommand, .toggle)
        bind(centre.nextTrackCommand, .next)
        bind(centre.previousTrackCommand, .previous)
        bind(centre.stopCommand, .stop)

        centre.changePlaybackPositionCommand.isEnabled = true
        let seekToken = centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.apply(.seek(position)) }
            return .success
        }
        targetTokens.append((centre.changePlaybackPositionCommand, seekToken))
    }

    private func bind(_ command: MPRemoteCommand, _ action: Action) {
        command.isEnabled = true
        // The command centre makes no promise about the calling thread.
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor in self?.apply(action) }
            return .success
        }
        targetTokens.append((command, token))
    }

    /// The transport side of a remote command.
    func apply(_ action: Action) {
        switch action {
        case .play:
            // Coming back from the media key with nothing loaded should start the
            // queue, which is what `toggle` already does.
            if !player.isPlaying { player.toggle() }
        case .pause:
            player.pause()
        case .toggle:
            player.toggle()
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .stop:
            player.stop()
        case .seek(let time):
            player.seek(to: time)
        }
        // The position lives in `ProgressClock`, which nothing here observes, so a
        // scrub from Control Center would otherwise leave the system believing the
        // old time until the next play/pause. `stop` also resets the position
        // after it flips `isPlaying`, so refreshing here keeps the order straight.
        refresh()
    }

    // MARK: - Now playing

    /// Republished from the player's own changes; call it directly after anything
    /// the observers cannot see.
    func refresh() {
        refreshCount &+= 1
        let centre = MPNowPlayingInfoCenter.default()
        guard let track = player.currentTrack else {
            centre.nowPlayingInfo = nil
            centre.playbackState = .stopped
            return
        }
        centre.nowPlayingInfo = Self.info(for: track,
                                          duration: player.duration,
                                          elapsed: player.progress,
                                          isPlaying: player.isPlaying,
                                          artwork: artwork(track))
        centre.playbackState = player.isPlaying ? .playing : .paused
    }

    private func refreshIfOnMain() {
        MainActor.assumeIsolated { refresh() }
    }

    /// Drops the registration on quit; otherwise the system keeps the media keys
    /// pointed at an app that is no longer there.
    func clear() {
        let centre = MPNowPlayingInfoCenter.default()
        centre.nowPlayingInfo = nil
        centre.playbackState = .stopped
    }

    /// The metadata dictionary. Pure, so the self-test can assert on it without
    /// touching the global now-playing store.
    static func info(for track: Track, duration: TimeInterval, elapsed: TimeInterval,
                     isPlaying: Bool, artwork: NSImage?) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyAlbumArtist: track.albumArtist,
            MPMediaItemPropertyPlaybackDuration: max(0, duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                artwork
            }
        }
        return info
    }
}
