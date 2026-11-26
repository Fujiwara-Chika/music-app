import SwiftUI
import AVFoundation

@MainActor
final class PlayerEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {

    // MARK: Published state

    @Published private(set) var currentTrack: Track? = nil
    @Published private(set) var duration: TimeInterval = 0
    /// Sequential → list loop → single loop → shuffle. Kept in UserDefaults so
    /// the app comes back the way it was left.
    @Published var playMode: PlayMode = .sequential {
        didSet { defaults.set(playMode.rawValue, forKey: PlayMode.storageKey) }
    }
    /// Volume has its own key (not the session snapshot) so it survives switching
    /// tracks. 100% is the default: the reference player ships at unity gain.
    static let volumeKey = "player.volume"
    /// One-shot: sessions saved before the default changed stored 0.72, and those
    /// would otherwise stick forever.
    static let volumeMigrationKey = "player.volume.migrated"

    @Published var volume: Double = 1.0 {
        didSet {
            let clamped = min(max(volume, 0), 1)
            if clamped != volume { volume = clamped; return }
            player?.volume = Float(volume)
            scheduleVolumePersist()
        }
    }
    /// Flushes the deferred volume write; called on quit so closing the app right
    /// after a drag does not lose the setting.
    func flushVolume() {
        volumePersistWork?.cancel()
        defaults.set(volume, forKey: Self.volumeKey)
    }

    /// Dragging the slider publishes on every frame; writing `UserDefaults` that
    /// often is pure overhead, so the write is deferred until the value settles
    /// (and repeated on quit, in case the app is closed mid-drag).
    private var volumePersistWork: DispatchWorkItem?
    private func scheduleVolumePersist() {
        volumePersistWork?.cancel()
        let value = volume
        let work = DispatchWorkItem { [defaults] in defaults.set(value, forKey: Self.volumeKey) }
        volumePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Where the small playback settings (volume, play mode) live. Injected so
    /// the self test can run against a scratch suite — a test run must not change
    /// what the user's next launch restores.
    private let defaults: UserDefaults

    /// High-frequency state lives in separate objects so that observing the engine
    /// does not redraw the whole window on every tick.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        playMode = PlayMode(rawValue: defaults.integer(forKey: PlayMode.storageKey)) ?? .sequential
        if defaults.bool(forKey: Self.volumeMigrationKey) {
            volume = min(max(defaults.double(forKey: Self.volumeKey), 0), 1)
        } else {
            volume = 1.0
            defaults.set(true, forKey: Self.volumeMigrationKey)
        }
    }

    let cursor = PlaybackCursor()
    let clock = ProgressClock()
    let bands = SpectrumBands()

    var isPlaying: Bool {
        get { cursor.isPlaying }
        set { cursor.isPlaying = newValue }
    }

    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }

    /// 56 smoothed spectrum values in 0...1, for the visualiser.
    var spectrum: [CGFloat] {
        get { bands.values }
        set { bands.values = newValue }
    }

    /// Called when a track starts, so the library can bump play counts.
    var onTrackStarted: ((Track) -> Void)?

    /// Whether the window is on screen, driven by its occlusion state. While it is
    /// occluded — another window on top, the app hidden or minimised — `tick`
    /// still persists the playhead but skips the progress/spectrum publishes and
    /// the meter, so nothing redraws for a window no one can see. Audio playback
    /// itself is unaffected.
    private(set) var uiIsVisible = true

    func setUIVisible(_ visible: Bool) {
        guard visible != uiIsVisible else { return }
        uiIsVisible = visible
        // Catch the UI up immediately so the bar is not stale on the way back in.
        if visible { tick() }
    }

    // MARK: Private

    private var player: AVAudioPlayer?
    private var queue: [Track] = []
    private var timer: Timer?
    private var simulatedClock: TimeInterval = 0
    /// Real FFT of the audio at the playhead (see SpectrumAnalyzer).
    private let analyzer = SpectrumAnalyzer()
    private var isAnalysisInFlight = false
    private var lastAnalysisAt = Date.distantPast
    /// Set once a track has handed over to the next one, so the timer and the
    /// player delegate cannot both advance on the same ending.
    private var endHandled = false
    private var lastPersistAt = Date.distantPast

    var isSimulated: Bool { currentTrack?.url == nil }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, progress / duration))
    }

    // MARK: - Transport API

    func play(_ track: Track, in tracks: [Track]) {
        if queue.map(\.id) != tracks.map(\.id) {
            queue = tracks
        }
        start(track)
    }

    func toggle() {
        guard currentTrack != nil else {
            if let first = queue.first { start(first) }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard isPlaying else { return }
        if let player { player.pause() }
        isPlaying = false
        stopTimer()
    }

    func resume() {
        guard let track = currentTrack else { return }
        guard track.url != nil else {
            isPlaying = true
            startTimer()
            return
        }
        if player == nil {
            start(track)
            return
        }
        player?.play()
        isPlaying = true
        syncCursor()
        startTimer()
    }

    func stop() {
        persistPlayback(force: true)
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        stopTimer()
        spectrum = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        analyzer.reset()
    }

    /// Cycles 顺序 → 列表循环 → 单曲循环 → 随机.
    func cyclePlayMode() {
        let all = PlayMode.allCases
        let index = all.firstIndex(of: playMode) ?? 0
        playMode = all[(index + 1) % all.count]
    }

    func next() {
        guard let current = currentTrack else {
            if let first = queue.first { start(first) }
            return
        }
        switch playMode {
        case .repeatOne:
            start(current)
        case .shuffle:
            guard let idx = queue.firstIndex(where: { $0.id == current.id }) else { return }
            start(queue[randomIndex(excluding: idx)])
        case .repeatAll:
            guard let idx = queue.firstIndex(where: { $0.id == current.id }) else { return }
            start(queue[(idx + 1) % queue.count])
        case .sequential:
            guard let idx = queue.firstIndex(where: { $0.id == current.id }) else { return }
            let nextIdx = idx + 1
            guard nextIdx < queue.count else {
                // End of the list: stop, keeping the track in the panel at 00:00.
                stop()
                return
            }
            start(queue[nextIdx])
        }
    }

    func previous() {
        guard let current = currentTrack else { return }
        if progress > 4 {
            seek(to: 0)
            return
        }
        guard let idx = queue.firstIndex(where: { $0.id == current.id }) else { return }
        if playMode == .shuffle, queue.count > 1 {
            start(queue[randomIndex(excluding: idx)])
            return
        }
        start(queue[(idx - 1 + queue.count) % queue.count])
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(duration, 0))
        progress = clamped
        player?.currentTime = clamped
        simulatedClock = clamped
        persistPlayback()
    }

    // MARK: - Resume across launches

    /// Writes the current track and playhead so the next launch can pick up where
    /// this one stopped. Called on a slow cadence from the tick, and instantly on
    /// pause / stop / seek / quit.
    func persistPlayback(force: Bool = false) {
        guard let track = currentTrack else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPersistAt) < 3 { return }
        lastPersistAt = now
        PlaybackMemory.save(PlaybackSnapshot(
            filePath: track.url?.path,
            album: track.album,
            albumArtist: track.albumArtist,
            title: track.title,
            trackNumber: track.trackNumber,
            position: progress,
            volume: volume,
            playMode: playMode.rawValue,
            savedAt: now
        ))
    }

    /// Puts the last session back on screen without starting playback.
    /// Returns the restored track so the table can select it.
    @discardableResult
    func restore(into tracks: [Track]) -> Track? {
        guard currentTrack == nil, let snapshot = PlaybackMemory.load() else { return nil }
        guard let track = tracks.first(where: { matches($0, snapshot) }) else { return nil }

        queue = tracks
        NSLog("音乐: engine restore \(track.title) self=\(ObjectIdentifier(self))")
        currentTrack = track
        syncCursor()
        duration = track.duration
        isPlaying = false
        if let mode = PlayMode(rawValue: snapshot.playMode) { playMode = mode }

        if let url = track.url {
            // Hand the file to the analyser first, so the meter has something to
            // read as soon as the first tick asks for it.
            analyzer.prepare(url: url)
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = Float(volume)
                p.delegate = self
                p.prepareToPlay()
                player = p
                if p.duration > 0 { duration = p.duration }
                let resumePoint = min(snapshot.position, max(0, p.duration - 0.5))
                p.currentTime = resumePoint
                progress = resumePoint
                simulatedClock = resumePoint
            } catch {
                progress = snapshot.position
            }
        } else {
            let resumePoint = min(snapshot.position, max(0, track.duration - 0.5))
            progress = resumePoint
            simulatedClock = resumePoint
        }
        return track
    }

    private func matches(_ track: Track, _ snapshot: PlaybackSnapshot) -> Bool {
        if let path = snapshot.filePath, let url = track.url, url.path == path { return true }
        return track.album == snapshot.album
            && track.albumArtist == snapshot.albumArtist
            && track.title == snapshot.title
            && track.trackNumber == snapshot.trackNumber
    }

    // MARK: - Internal playback

    /// Keeps the row marker in sync with the playing track.
    private func syncCursor() {
        cursor.trackID = currentTrack?.id
    }

    private func start(_ track: Track) {
        NSLog("音乐: engine start \(track.title) self=\(ObjectIdentifier(self))")
        player?.stop()
        player = nil
        currentTrack = track
        syncCursor()
        progress = 0
        duration = track.duration
        simulatedClock = 0
        endHandled = false

        if let url = track.url {
            // Hand the file to the analyser first, so the meter has something to
            // read as soon as the first tick asks for it.
            analyzer.prepare(url: url)
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = Float(volume)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                player = p
                if p.duration > 0 { duration = p.duration }
            } catch {
                NSLog("播放失败 \(url.lastPathComponent): \(error.localizedDescription)")
            }
        } else {
            analyzer.reset()
        }

        isPlaying = true
        startTimer()
        onTrackStarted?(track)
    }

    private func randomIndex(excluding idx: Int) -> Int {
        guard queue.count > 1 else { return idx }
        var candidate = idx
        while candidate == idx {
            candidate = Int.random(in: 0..<queue.count)
        }
        return candidate
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        persistPlayback()

        if let player {
            // Occluded/minimised: the audio player advances itself, so there is
            // nothing to drive here — skip publishing and the meter for a window
            // that cannot be seen.
            guard uiIsVisible else { return }
            progress = player.currentTime
            // Only publish a new duration when it really changed: assigning the
            // same value every tick invalidates every observer of the engine
            // (the whole window plus every visible row) on every tick.
            let reported = player.duration
            if reported > 0, abs(reported - duration) > 0.05 { duration = reported }
            requestSpectrum()
            // AVAudioPlayer resets currentTime to 0 once it reaches the end, so
            // the position alone cannot tell us the track finished — the delegate
            // above is the reliable signal. This branch only catches players that
            // stop without firing it.
            if !player.isPlaying, progress >= duration - 0.15, duration > 0, isPlaying {
                handleTrackEnd()
                return
            }
        } else {
            // Simulated transport for the bundled demo library. Only tracks that
            // genuinely have no file take this path: a file that failed to open
            // must not look like it is playing.
            guard currentTrack?.url == nil else {
                isPlaying = false
                stopTimer()
                return
            }
            // No delegate fires for the simulated clock, so it has to keep
            // advancing even while the window is hidden — a real file keeps
            // playing when occluded, and the demo must behave the same. Only the
            // publishes/meter are skipped for an unseen window.
            simulatedClock += 1.0 / 15.0
            if uiIsVisible {
                progress = simulatedClock
                // The demo library has no files behind it, so there is no PCM to
                // analyse — the meter sits at rest instead of faking a curve.
                if spectrum.contains(where: { $0 > 0 }) {
                    spectrum = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
                }
            }
            if simulatedClock >= duration, duration > 0 {
                handleTrackEnd()
                return
            }
        }
    }

    /// Called by the timer (and by the player delegate) when a track runs out.
    /// Guarded so one ending never advances twice.
    func handleTrackEnd() {
        guard !endHandled else { return }
        endHandled = true
        next()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handleTrackEnd()
        }
    }

    // MARK: - Spectrum

    /// Asks the analyser for the bands at the current playhead. One request is
    /// in flight at a time so a slow disk read cannot pile up.
    private func requestSpectrum() {
        // 12 Hz is plenty for the LED meter and roughly halves the decode cost:
        // every sample needs a seek + AAC decode in the analyser. Measured while
        // playing a real track: 20 Hz ≈ +5% CPU, 12 Hz ≈ +2%, and 8 Hz bought
        // nothing measurable over 12, so the meter's appearance is the limit.
        guard Date().timeIntervalSince(lastAnalysisAt) >= 1.0 / 12.0 else { return }
        lastAnalysisAt = Date()
        guard !isAnalysisInFlight, let track = currentTrack, track.url != nil else { return }
        isAnalysisInFlight = true
        let position = progress
        analyzer.bands(at: position) { [weak self] values in
            guard let self else { return }
            self.isAnalysisInFlight = false
            self.spectrum = values
        }
    }

    /// Offscreen rendering has no timer, so the analyser is asked synchronously.
    func settleSpectrumForRender(at time: Double? = nil) {
        guard let track = currentTrack, track.url != nil else {
            spectrum = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
            return
        }
        spectrum = analyzer.bandsSync(at: time ?? progress)
    }

    // MARK: - Formatting

    var elapsedText: String { Self.clock(progress) }
    var durationText: String { Self.clock(duration) }

    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00:00" }
        let total = Int(t.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
