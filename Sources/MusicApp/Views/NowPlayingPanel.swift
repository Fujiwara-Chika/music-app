import SwiftUI
import AppKit

/// Right-hand "now playing" column: artwork, rating, metadata, lyrics and spectrum.
///
/// The panel always mirrors the transport: while a track plays it shows
/// `player.currentTrack`, otherwise it falls back to the row selected in the table.
struct NowPlayingPanel: View {
@Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore
@EnvironmentObject private var artworkTicker: ArtworkTicker
    @EnvironmentObject private var player: PlayerEngine

    /// Ratings applied to a track that is playing but is not part of the library.
    /// (Imported tracks live in the library, so this is only a safety net.)
    @State private var detachedRatings: [UUID: Int] = [:]

    private enum Layout {
        static let horizontalPadding: CGFloat = 4
        static let topPadding: CGFloat = 6       // the cover sits right under the toolbar row
        static let coverHeight: CGFloat = 212      // reference: 251 x 212, not square
        static let coverGap: CGFloat = 27          // cover bottom -> rating row
        static let ratingGap: CGFloat = 6          // rating row -> title
        static let titleGap: CGFloat = 12          // title -> format line
        static let lyricsBottom: CGFloat = 45      // lyrics block -> spectrum
        static let spectrumHeight: CGFloat = 36
    }

    // MARK: - Derived state

    /// Identity comes from the player, but ratings and play counts are read back
    /// through the store: `player.currentTrack` is a value copy frozen at play
    /// time, so it would keep showing "0次" forever.
    private var track: Track? {
        if let current = player.currentTrack, let stored = store.track(id: current.id) { return stored }
        return player.currentTrack ?? store.selectedTrack
    }

    private var rating: Int {
        guard let track else { return 0 }
        // Always read the library copy so a tap is reflected immediately.
        if let stored = store.track(id: track.id) { return stored.rating }
        return detachedRatings[track.id] ?? track.rating
    }

    /// Decoded artwork. The `.task` below re-reads it whenever the album changes,
    /// which covers the case where the cache was still empty on the first frame.
    @State private var loadedArtwork: NSImage?

    private var artwork: NSImage? {
        if let loadedArtwork { return loadedArtwork }
        return track.flatMap { store.artwork(for: $0.albumKey) }
    }

    // MARK: - Body

    var body: some View {
        panel
            .onChange(of: artworkTicker.revision(for: (player.currentTrack ?? store.selectedTrack)?.albumKey ?? "")) { _, _ in
                loadedArtwork = track.flatMap { store.artwork(for: $0.albumKey) }
            }
            .task(id: track?.albumKey) {
                loadedArtwork = track.flatMap { store.artwork(for: $0.albumKey) }
            }
    }

    private var panel: some View {
        GeometryReader { geometry in
            let coverWidth = max(1, geometry.size.width - Layout.horizontalPadding * 2)

            VStack(spacing: 0) {
                cover(width: coverWidth, height: Layout.coverHeight)
                    .padding(.bottom, Layout.coverGap)

                ratingRow
                    .padding(.bottom, Layout.ratingGap)

                Text(track?.title ?? "")
                    .font(Typo.panelTitle)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Layout.titleGap)

                Text(track?.formatText ?? "")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                // The demo albums that mirror the reference screenshot have no
                // files behind them, so say so instead of letting the transport
                // tick away silently.
                if let track, track.url == nil {
                    Text("示例曲目 · 没有音频文件")
                        .font(Typo.panelMeta)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }

                Spacer(minLength: 12)

                lyrics
                    .padding(.bottom, Layout.lyricsBottom)

                SpectrumView()
                    .frame(height: Layout.spectrumHeight)
            }
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.topPadding)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.panelBG)
        .clipped()
    }

    // MARK: - Cover

    private func cover(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            palette.controlBG

            if let artwork {
                // Pre-crop to the panel's aspect instead of asking SwiftUI to
                // fill-and-clip: `ImageRenderer` drops clipped images for some
                // bitmaps, which left the offscreen screenshots cover-less.
                Image(nsImage: Self.filled(artwork, width: width, height: height))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
            } else {
                Image(systemName: "opticaldisc")
                    .font(.system(size: max(28, height * 0.42), weight: .light))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay(
            Rectangle()
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
        )
    }

    /// Draws `image` at `width` × `height` with the "aspect fill" crop baked in.
    static func filled(_ image: NSImage, width: CGFloat, height: CGFloat) -> NSImage {
        let scale = 2.0
        let pixels = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard pixels.width >= 1, pixels.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }
        let ratio = max(pixels.width / source.width, pixels.height / source.height)
        let drawn = CGSize(width: source.width * ratio, height: source.height * ratio)
        let origin = CGPoint(x: (pixels.width - drawn.width) / 2, y: (pixels.height - drawn.height) / 2)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: origin, size: drawn),
                   from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            rep.draw(in: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
            return true
        }
    }

    // MARK: - Rating

    private var ratingRow: some View {
        HStack(spacing: 3) {
            Image(systemName: "bookmark")
                .font(.system(size: 15))
                .foregroundStyle(Theme.starOff)
                .frame(width: 18, height: 22)

            ForEach(1...5, id: \.self) { value in
                Button {
                    setRating(value)
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(value <= rating ? Theme.text
                                                         : Theme.starOff.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyrics: some View {
        let lyricist = track?.lyricist ?? ""
        let composer = track?.composer ?? ""
        let lines = track?.lyrics ?? []

        if !lyricist.isEmpty || !composer.isEmpty || !lines.isEmpty {
            VStack(spacing: 8) {
                if !lyricist.isEmpty {
                    Text("作词：\(lyricist)")
                        .font(Typo.lyrics)
                        .foregroundStyle(Theme.textSecondary)
                }

                if !composer.isEmpty {
                    Text("作曲：\(composer)")
                        .font(Typo.lyrics)
                        .foregroundStyle(palette.accent)
                }

                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(Typo.lyrics)
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(8)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private func setRating(_ value: Int) {
        guard let track else { return }
        if store.track(id: track.id) != nil {
            // The library holds the canonical copy, including for the playing track.
            store.setRating(value, for: track.id)
        } else {
            detachedRatings[track.id] = value
        }
    }
}
