import SwiftUI
import AppKit

/// Owns the cover-derived palette: whenever the playing (or selected) track
/// changes, it samples that album's artwork and publishes the new ladder.
@MainActor
final class ThemeController: ObservableObject {
    @Published private(set) var palette: Palette = .reference

    private var cache: [String: Palette] = [:]
    private var currentKey: String?

    /// `key` identifies the album; passing an artwork-less key falls back to the
    /// reference palette so the initial launch looks like the screenshot.
    func adopt(artwork: NSImage?, albumKey: String?) {
        guard let albumKey else {
            currentKey = nil
            if palette != .reference { palette = .reference }
            return
        }
        currentKey = albumKey

        // Covers decode off the main thread, so the first request for an album
        // often has no bitmap yet. Cache only real derivations: caching the
        // fallback would pin that album to the reference palette for the rest
        // of the session, even after the artwork arrives.
        if let artwork {
            let derived: Palette
            if let cached = cache[albumKey] {
                derived = cached
            } else {
                derived = Palette.derive(from: artwork)
                cache[albumKey] = derived
            }
            if derived != palette { palette = derived }
            return
        }

        if let cached = cache[albumKey] {
            if cached != palette { palette = cached }
        } else if palette != .reference {
            palette = .reference
        }
    }
}
