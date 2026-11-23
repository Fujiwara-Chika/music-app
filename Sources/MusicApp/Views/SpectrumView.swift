import SwiftUI

/// The 56-bar spectrum strip along the bottom of the now-playing panel.
///
/// The reference draws a segmented LED meter: every bar is a stack of 1pt-tall
/// cells with a sub-pixel gap between them, coloured by their absolute height in
/// the strip (teal at the bottom, green in the middle, amber at the top), plus a
/// detached peak-hold cell floating above the bar. All of that is drawn in one
/// `Canvas` pass so the cell grid stays pixel crisp.
struct SpectrumView: View {
    @EnvironmentObject private var bands: SpectrumBands

    /// Slowly decaying peak per column; the detached cell above each bar.
    @State private var peaks: [CGFloat] = Array(repeating: 0, count: Spectrum.columns)

    private enum Spectrum {
        static let columns = 56
        static let barWidth: CGFloat = 2.6
        static let cellHeight: CGFloat = 1.25
        static let cellPitch: CGFloat = 1.6
        /// How fast a peak falls back when the bar drops (per update).
        static let peakDecay: CGFloat = 0.02

        /// Bottom → top colour ramp, sampled from the reference.
        static let ramp: [(stop: CGFloat, color: (CGFloat, CGFloat, CGFloat))] = [
            (0.00, (0.18, 0.55, 0.53)),
            (0.40, (0.34, 0.64, 0.37)),
            (0.62, (0.60, 0.72, 0.26)),
            (0.82, (0.86, 0.69, 0.20))
        ]

        static func color(at fraction: CGFloat) -> Color {
            let f = min(1, max(0, fraction))
            for index in 1..<ramp.count where f <= ramp[index].stop {
                let lower = ramp[index - 1]
                let upper = ramp[index]
                let span = upper.stop - lower.stop
                let t = span > 0 ? (f - lower.stop) / span : 0
                return Color(
                    red: lower.color.0 + (upper.color.0 - lower.color.0) * t,
                    green: lower.color.1 + (upper.color.1 - lower.color.1) * t,
                    blue: lower.color.2 + (upper.color.2 - lower.color.2) * t
                )
            }
            let last = ramp[ramp.count - 1].color
            return Color(red: last.0, green: last.1, blue: last.2)
        }
    }

    var body: some View {
        Canvas { context, size in
            let height = size.height
            guard height > 4, size.width > 4 else { return }
            let pitch = size.width / CGFloat(Spectrum.columns)
            let cells = max(1, Int(height / Spectrum.cellPitch))

            for column in 0..<Spectrum.columns {
                let value = level(column)
                let x = CGFloat(column) * pitch + (pitch - Spectrum.barWidth) / 2

                // Lit cells, bottom up.
                let lit = Int((min(1, value * 1.06) * CGFloat(cells)).rounded())
                for cell in 0..<lit {
                    let y = height - CGFloat(cell + 1) * Spectrum.cellPitch
                    let rect = CGRect(x: x,
                                      y: y,
                                      width: Spectrum.barWidth,
                                      height: Spectrum.cellHeight)
                    let fraction = (CGFloat(cell) + 0.5) / CGFloat(cells)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.35),
                                 with: .color(Spectrum.color(at: fraction)))
                }

                // Detached peak-hold cell.
                let peak = peaks[column]
                if peak > value + 0.02 {
                    let cell = min(cells - 1, Int((peak * CGFloat(cells)).rounded()))
                    let y = height - CGFloat(cell + 1) * Spectrum.cellPitch
                    let rect = CGRect(x: x,
                                      y: y,
                                      width: Spectrum.barWidth,
                                      height: Spectrum.cellHeight)
                    let fraction = (CGFloat(cell) + 0.5) / CGFloat(cells)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.35),
                                 with: .color(Spectrum.color(at: fraction).opacity(0.55)))
                }
            }
        }
        .onChange(of: bands.values) { _, values in
            var next = peaks
            for index in 0..<Spectrum.columns {
                let value = index < values.count ? min(1, max(0, CGFloat(values[index]))) : 0
                next[index] = value >= next[index] ? value : max(value, next[index] - Spectrum.peakDecay)
            }
            peaks = next
        }
    }

    private func level(_ index: Int) -> CGFloat {
        index < bands.values.count ? min(1, max(0, CGFloat(bands.values[index]))) : 0
    }
}
