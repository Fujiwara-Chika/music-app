import SwiftUI
import AppKit

/// Dev-only: renders the transport's play-mode glyphs offscreen so their shapes
/// can be checked without a window (and without stealing the user's screen).
///
///     Music --render-icons /tmp/modes.png
@MainActor
enum IconPreview {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-ui"), index + 1 < args.count {
            renderUI(URL(fileURLWithPath: args[index + 1]))
        }
        if let index = args.firstIndex(of: "--render-transport"), index + 1 < args.count {
            renderTransport(URL(fileURLWithPath: args[index + 1]))
        }
        guard let index = args.firstIndex(of: "--render-icons"), index + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[index + 1])

        let strip = HStack(spacing: 14) {
            ForEach(PlayMode.allCases) { mode in
                SkinIcon(glyph: mode.glyph,
                         color: mode == .sequential ? Theme.text : Theme.accent)
                    .frame(width: 17, height: 17)
                    .frame(width: 34, height: 28)
            }
        }
        .padding(12)
        .background(Theme.transportBG)

        let renderer = ImageRenderer(content: strip)
        renderer.scale = 4
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: output)
            print("rendered \(output.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The arguments that follow a flag, up to the next `--flag`.
    private static func args(after flag: String) -> [String] {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag) else { return [] }
        var found: [String] = []
        for value in args[(index + 1)...] {
            if value.hasPrefix("--") { break }
            found.append(value)
        }
        return found
    }

    /// Renders the entire window offscreen — no window server involvement, so the
    /// UI can be checked while the user is working on something else.
    private static func renderUI(_ output: URL) -> Never {
        // Cache-only: render the real library when there is a snapshot, without
        // ever walking the disk from a screenshot tool.
        let store = LibraryStore(cacheOnly: true)
        // Keep whatever the store restored; the demo is only the fallback.
        if store.tracks.isEmpty { store.loadDemoLibrary() }
        let player = PlayerEngine()
        // Optional second argument: render with a specific track, which is how the
        // cover-derived palette is checked against a non-navy cover.
        let requestedTitle = args(after: "--render-ui").dropFirst().first
        let preferred = requestedTitle.flatMap { title in
            store.tracks.first(where: { $0.title == title })
        }
        if let track = preferred ?? store.tracks.first(where: { $0.title == "キズナ" }) ?? store.tracks.first {
            player.play(track, in: store.allVisibleTracks)
            player.seek(to: 20)
            player.volume = 1.0
            player.settleSpectrumForRender()
        }

        RenderMode.isOffscreen = true
        // Offscreen rendering has no run loop, so the async artwork decode would
        // never land and every cover would come out as the placeholder disc.
        // Read the cached bitmaps synchronously for every album the table shows.
        // Only the rows the render can show matter, and the cache budget is
        // ~40 covers at 768px — warming the whole library just evicts itself.
        var seen = Set<String>()
        var warmed = 0
        for row in store.rows where seen.count < 28 {
            guard let group = row.group, seen.insert(group.albumKey).inserted else { continue }
            if store.artworkNow(for: group.albumKey) != nil { warmed += 1 }
        }
        print("render: warmed \(warmed) covers for the first \(seen.count) albums")
        // Let the renderer show the cover-derived chrome: sample the artwork that
        // the restored track will show in the panel.
        let themeTrack = player.currentTrack ?? store.selectedTrack
        let override: Palette? = themeTrack.flatMap { track in
            store.artworkNow(for: track.albumKey).map { Palette.derive(from: $0) }
        }
        let view = RootView(paletteOverride: override)
            .environmentObject(store)
            .environmentObject(store.artworkTicker)
            .environmentObject(player)
            .environmentObject(player.cursor)
            .environmentObject(player.clock)
            .environmentObject(player.bands)
            .frame(width: Metrics.windowWidth, height: Metrics.windowHeight)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        try? png.write(to: output)
        print("rendered \(output.path)")
        exit(0)
    }

    /// Renders the whole transport bar with the demo track loaded, so the play
    /// mode button can be reviewed without opening a window.
    private static func renderTransport(_ output: URL) -> Never {
        let store = LibraryStore(autoLoad: false)
        store.loadDemoLibrary()
        let player = PlayerEngine()
        if let first = store.tracks.first {
            player.play(first, in: store.tracks)
        }
        player.seek(to: 20)
        if let modeIndex = args(after: "--render-transport").compactMap({ Int($0) }).first,
           let mode = PlayMode(rawValue: modeIndex) {
            player.playMode = mode
        }

        let bar = TransportBar()
            .environmentObject(player)
            .environmentObject(store)
            .environmentObject(player.cursor)
            .environmentObject(player.clock)
            .environmentObject(player.bands)
            .frame(width: Metrics.windowWidth, height: Metrics.transportHeight)

        let renderer = ImageRenderer(content: bar)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: output)
            print("rendered \(output.path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
