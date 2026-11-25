import SwiftUI
import AppKit

@main
struct MusicAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var player = PlayerEngine()

    init() {
        // `音乐 --self-test [folder]` verifies scanning + playback without a window.
        SelfTest.runIfRequested()
        IconPreview.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
            .environmentObject(store.artworkTicker)
                .environmentObject(player)
                .environmentObject(player.cursor)
                .environmentObject(player.clock)
                .environmentObject(player.bands)
                .preferredColorScheme(.dark)
                .background(Color.clear)
                .frame(minWidth: 940, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Metrics.windowWidth, height: Metrics.windowHeight)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("导入音乐文件夹…") { store.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("重新扫描资料库") { store.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("载入示例资料库") { store.loadDemoLibrary() }
            }
            CommandMenu("播放") {
                Button("播放 / 暂停") { player.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("下一首") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Menu("播放模式") {
                    ForEach(PlayMode.allCases) { mode in
                        Button {
                            player.playMode = mode
                        } label: {
                            if mode == player.playMode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                }
                Button("切换播放模式") { player.cyclePlayMode() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Dragging by the background keeps the chrome usable. AppKit then walks
            // the view tree per commit for its draggable regions (measured ~5% of the
            // main thread while scrolling), so a custom grip view was tried — but
            // SwiftUI never routes the mouse-down there, and losing window dragging
            // would be a regression.
            window.isMovableByWindowBackground = true
            // A real translucent window: the backdrop draws the cover and the
            // palette wash, so anything below full opacity lets the desktop
            // through instead of showing an opaque sheet.
            window.isOpaque = false
            window.backgroundColor = .clear
            // The real traffic lights, in their usual place: a transparent title
            // bar with the system buttons is what makes a window read as macOS.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.isHidden = false
            }
            window.setContentSize(NSSize(width: Metrics.windowWidth, height: Metrics.windowHeight))
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Root layout

struct RootView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    /// Only used by the offscreen renderer, which cannot wait for a track change.
    var paletteOverride: Palette? = nil
    @StateObject private var theme = ThemeController()
    @StateObject private var appearance = AppearanceSettings()
    /// Cover behind the window. `artwork(for:)` is async on a cold cache, so the
    /// backdrop keeps its own state and fills in when the bitmap lands.
    @State private var backdropArtwork: NSImage?
    /// Only the album matters: `.task` awaits the thumbnail itself, so keying on
    /// the global artwork ticker would re-render the whole window every time a
    /// row's cover finished decoding.
    private var backdropKey: String {
        let album = (player.currentTrack ?? store.selectedTrack)?.albumKey ?? ""
        return album + (appearance.usesArtworkBackdrop ? "#on" : "#off")
    }

    /// Restoring runs once, as soon as the library has tracks to match against.
    @State private var hasRestoredSession = false

    private var shownPalette: Palette {
        (paletteOverride ?? theme.palette).washed(by: appearance.backgroundOpacity)
    }

    var body: some View {
        let shown = shownPalette
        return VStack(spacing: 0) {
            TopBar()
                .frame(height: Metrics.topBarHeight)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    FilterStrip()
                        .frame(height: Metrics.headerRowHeight)
                    SidebarView()
                        .frame(maxHeight: .infinity)
                }
                .frame(width: Metrics.sidebarWidth)
                .background(shown.windowBG)

                SongTable(actions: SongTableActions(
                    play: { player.play($0, in: $1) },
                    toggle: { player.toggle() },
                    next: { player.next() }
                ), cursor: player.cursor, clock: player.clock)
                    .frame(maxWidth: .infinity)

                NowPlayingPanel()
                    .frame(width: Metrics.panelWidth)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(palette.separator).frame(height: 1)

            TransportBar()
                .frame(height: Metrics.transportHeight)
        }
        .background {
            WindowBackdrop(
                palette: shown,
                artwork: appearance.usesArtworkBackdrop ? backdropArtwork : nil,
                blur: appearance.backgroundBlur,
                opacity: appearance.backgroundOpacity
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.palette, shown)
        .environmentObject(appearance)
        .animation(.easeInOut(duration: 0.45), value: theme.palette.token)
        .task(id: backdropKey) {
            guard appearance.usesArtworkBackdrop,
                  let albumKey = (player.currentTrack ?? store.selectedTrack)?.albumKey else {
                backdropArtwork = nil
                return
            }
            if let cached = store.cachedThumbnail(for: albumKey, maxPixel: 420) {
                backdropArtwork = cached
            } else {
                backdropArtwork = await store.thumbnailAsync(for: albumKey, maxPixel: 420)
            }
        }
        .onAppear(perform: applyLaunchOverrides)
        .onChange(of: store.tracks.count) { _, _ in
            restoreSessionIfPossible()
            adoptCurrentPalette()
        }
        .onChange(of: player.currentTrack?.id) { _, _ in adoptCurrentPalette() }
        .onChange(of: theme.palette.token) { _, _ in
            // Keep the window itself in step, so resizing never reveals a seam.
            // Stays clear: the backdrop paints the window, and a coloured window
            // background would make the opacity slider do nothing.
            NSApp.keyWindow?.backgroundColor = .clear
        }
        .onChange(of: store.selectedTrackID) { _, _ in adoptCurrentPalette() }
        // Covers decode in the background; when one lands the chrome has to
        // re-derive or a cold start would stay navy for the whole session.
        .onChange(of: store.artworkTicker.revision) { _, _ in adoptCurrentPalette() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            player.persistPlayback(force: true)
            player.flushVolume()
            // The library snapshot is debounced by 2s, so a playlist or rating
            // made just before ⌘Q would otherwise never reach the disk.
            store.flushSnapshot()
        }
    }

    // MARK: - Session restore and cover-derived palette

    /// Brings back the track and playhead the app was closed on. Skipped when a
    /// launch override (demo autoplay / explicit import) is driving the session.
    private func restoreSessionIfPossible() {
        guard !hasRestoredSession, !store.tracks.isEmpty else { return }
        hasRestoredSession = true
        guard !CommandLine.arguments.contains("--autoplay") else { return }
        // Match against the whole library: a filter left over from last launch
        // must not hide the restored track from the matcher.
        if let track = player.restore(into: store.tracks) {
            store.selectedTrackID = track.id
        }
        adoptCurrentPalette()
    }

    /// The whole chrome takes its cast from the album that is on screen.
    private func adoptCurrentPalette() {
        let track = player.currentTrack ?? store.selectedTrack
        theme.adopt(artwork: track.flatMap { store.artwork(for: $0.albumKey) }, albumKey: track?.albumKey)
    }

    /// Development hook: `--autoplay [seconds]` starts the demo track so screenshots
    /// (and manual smoke tests) show the playing state, exactly like the reference.
    /// The optional number seeks that many seconds in, which is what the reference
    /// screenshot shows.
    ///
    /// Arguments rather than an environment variable: apps started by LaunchServices
    /// do not inherit a shell environment, while `open ... --args` always works.
    private func applyLaunchOverrides() {
        let arguments = CommandLine.arguments
        appearance.applyLaunchOverrides()

        // Debug: jump the table to a fraction of the list, so scrolling cost can be
        // measured at depth (synthetic wheel events cannot reach deep positions).
        if let index = arguments.firstIndex(of: "--scroll-fraction"),
           index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let rows = store.rows
                guard !rows.isEmpty else { return }
                let target = min(rows.count - 1, max(0, Int(value * Double(rows.count - 1))))
                store.requestScroll(to: rows[target].id)
            }
        }

        // Play counts and the history / most-played sides of the sidebar feed off
        // this callback; without it they stay empty no matter how much you play.
        player.onTrackStarted = { track in
            store.notePlay(track)
            // Auto-advance at the end of a song (and explicit next/previous) keeps
            // the playing row in view instead of leaving the list where it was.
            store.reveal(trackID: track.id)
        }

        // The cached library is ready before `onAppear`, so the count observer
        // never fires on a warm launch — restore and sample the palette here.
        DispatchQueue.main.async {
            restoreSessionIfPossible()
            // Sharpen the covers cached by older builds, without blocking launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                store.startArtworkUpgradePass()
            }
            adoptCurrentPalette()
        }

        // `--import <folder>` loads a real music folder instead of the demo library,
        // so screenshots and manual runs can be checked against real metadata.
        if let flag = arguments.firstIndex(of: "--import"), arguments.count > flag + 1 {
            let folder = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath)
            Task { @MainActor in await store.scan(folder: folder) }
        }

        if let flag = arguments.firstIndex(of: "--filter"), arguments.count > flag + 1 {
            store.filterText = arguments[flag + 1]
        }

        guard let flag = arguments.firstIndex(of: "--autoplay") else { return }
        let seekTo = arguments.count > flag + 1 ? Double(arguments[flag + 1]) : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let tracks = store.allVisibleTracks
            guard let track = tracks.first(where: { $0.title == "キズナ" }) ?? tracks.first else { return }
            store.selectedTrackID = track.id
            player.play(track, in: tracks)
            if let seekTo, seekTo > 1 {
                player.seek(to: seekTo)
            }
        }
    }
}

/// The "过滤" search strip that sits in the column-header row above the sidebar.
/// It mirrors the reference: a 112pt search field, a 1pt divider, then the
/// right-aligned count of rows that currently pass the filter.
struct FilterStrip: View {
@Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                ZStack(alignment: .leading) {
                    if store.filterText.isEmpty {
                        Text("过滤")
                            .font(Typo.row)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if RenderMode.isOffscreen {
                        Text(store.filterText)
                            .font(Typo.row)
                            .foregroundStyle(Theme.text)
                    } else {
                        TextField("", text: $store.filterText)
                            .textFieldStyle(.plain)
                            .font(Typo.row)
                            .foregroundStyle(Theme.text)
                            .focused($focused)
                    }
                }
                if !store.filterText.isEmpty {
                    Button {
                        store.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 3)
            .frame(width: 112, alignment: .leading)

            Rectangle()
                .fill(palette.separator)
                .frame(width: 1)

            // The reference shows the number of albums currently in view here;
            // during a scan the same slot carries a spinner and the file count.
            HStack(spacing: 5) {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.62)
                        .frame(width: 10, height: 10)
                        .help("正在扫描资料库…")
                }
                Text(verbatim: "\(store.groups.count)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(store.isScanning ? Theme.textSecondary : Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.columnHeader)
        .clipped()
    }
}

