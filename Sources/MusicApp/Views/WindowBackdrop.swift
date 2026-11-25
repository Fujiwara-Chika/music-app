import AppKit
import SwiftUI

/// The layer behind everything: the current cover, blurred by the slider, with the
/// palette's wash on top. At opacity 1.0 the wash is opaque, i.e. the old look.
struct WindowBackdrop: View {
    let palette: Palette
    let artwork: NSImage?
    let blur: Double
    let opacity: Double

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: blur, opaque: true)
                    .saturation(1.25)
                    .overlay(Color.black.opacity(0.22))
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
