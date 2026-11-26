import AppKit
import SwiftUI

/// The layer behind everything: the current cover, blurred by the slider, with the
/// palette's wash on top. The cover itself stays opaque on purpose — the opacity
/// slider is about how much of it you see through the surfaces above, not about
/// letting the desktop through.
struct WindowBackdrop: View {
    let palette: Palette
    let artwork: NSImage?
    let blur: Double
    /// How opaque the surfaces above are. The more of the cover shows through,
    /// the more it has to be darkened, or text over a bright sleeve loses contrast.
    let opacity: Double

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: blur, opaque: true)
                    .saturation(1.25)
                    .overlay(Color.black.opacity(0.22 + (1 - opacity) * 0.45))
                    .clipped()
            } else {
                LinearGradient(
                    colors: [palette.controlBG, palette.windowBG],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            palette.windowBG
        }
        .ignoresSafeArea()
    }
}
