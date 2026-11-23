import SwiftUI

/// Vector glyphs for the transport, redrawn from the reference's own icon set.
///
/// The reference UI draws its chrome with thin single-stroke outlines (about
/// 1.2–1.6pt) instead of filled SF Symbols, so the built-in symbol set can only
/// approximate it. Every glyph below is authored in a 24x24 design box and
/// scaled to the requested frame, which keeps the stroke weight constant in
/// points no matter how large the glyph is rendered.
enum SkinGlyph {
    // Transport
    case previous
    case next
    case play
    case pause
    case stop
    case shuffle
    case sequential
    case repeatAll
    case repeatOne
}

struct SkinIcon: View {
    let glyph: SkinGlyph
    var color: Color = Theme.text
    /// Stroke width in points (the design box is 24 units across).
    var lineWidth: CGFloat = 1.35

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            let scale = side / 24
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: (size.width / scale - 24) / 2,
                                y: (size.height / scale - 24) / 2)

            let style = StrokeStyle(lineWidth: lineWidth / scale,
                                    lineCap: .round,
                                    lineJoin: .round)
            let ink = GraphicsContext.Shading.color(color)

            func stroke(_ path: Path, width: CGFloat? = nil) {
                var style = style
                if let width { style.lineWidth = width / scale }
                context.stroke(path, with: ink, style: style)
            }
            func fill(_ path: Path) {
                context.fill(path, with: ink)
            }
            func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat? = nil) {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                stroke(path, width: width)
            }
            func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius,
                                       y: center.y - radius,
                                       width: radius * 2,
                                       height: radius * 2))
            }
            func polygon(_ points: [CGPoint], closed: Bool = true) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                if closed { path.closeSubpath() }
                return path
            }

            switch glyph {
            // MARK: Transport

            case .previous:
                fill(Path(CGRect(x: 2.2, y: 4.4, width: 1.3, height: 19.4)))
                stroke(polygon([CGPoint(x: 20.6, y: 3.3),
                                CGPoint(x: 20.6, y: 20.7),
                                CGPoint(x: 4.9, y: 12.0)]),
                       width: 1.1)

            case .next:
                fill(Path(CGRect(x: 20.5, y: 4.4, width: 1.3, height: 19.4)))
                stroke(polygon([CGPoint(x: 3.4, y: 3.3),
                                CGPoint(x: 3.4, y: 20.7),
                                CGPoint(x: 19.1, y: 12.0)]),
                       width: 1.1)

            case .play:
                stroke(polygon([CGPoint(x: 6.6, y: 3.7),
                                CGPoint(x: 6.6, y: 20.3),
                                CGPoint(x: 19.6, y: 12.0)]),
                       width: 1.1)

            case .pause:
                fill(Path(CGRect(x: 8.4, y: 4.6, width: 1.3, height: 14.8)))
                fill(Path(CGRect(x: 14.3, y: 4.6, width: 1.3, height: 14.8)))

            case .stop:
                stroke(Path(CGRect(x: 2.4, y: 2.4, width: 19.2, height: 19.2)),
                       width: 1.15)

            /// Two crossing arrows, the shape the reference uses for shuffle.
            case .shuffle:
                var upper = Path()
                upper.move(to: CGPoint(x: 2.2, y: 6.6))
                upper.addLine(to: CGPoint(x: 7.6, y: 6.6))
                upper.addLine(to: CGPoint(x: 16.4, y: 17.4))
                upper.addLine(to: CGPoint(x: 21.6, y: 17.4))
                stroke(upper, width: 1.25)
                line(CGPoint(x: 18.6, y: 14.8), CGPoint(x: 21.6, y: 17.4), width: 1.25)
                line(CGPoint(x: 18.6, y: 20.0), CGPoint(x: 21.6, y: 17.4), width: 1.25)

                var lower = Path()
                lower.move(to: CGPoint(x: 2.2, y: 17.4))
                lower.addLine(to: CGPoint(x: 7.6, y: 17.4))
                lower.addLine(to: CGPoint(x: 16.4, y: 6.6))
                lower.addLine(to: CGPoint(x: 21.6, y: 6.6))
                stroke(lower, width: 1.25)
                line(CGPoint(x: 18.6, y: 4.0), CGPoint(x: 21.6, y: 6.6), width: 1.25)
                line(CGPoint(x: 18.6, y: 9.2), CGPoint(x: 21.6, y: 6.6), width: 1.25)

            /// A plain right arrow: play through the list once, then stop.
            case .sequential:
                line(CGPoint(x: 3.4, y: 12), CGPoint(x: 20.2, y: 12), width: 1.35)
                line(CGPoint(x: 14.6, y: 6.4), CGPoint(x: 20.2, y: 12), width: 1.35)
                line(CGPoint(x: 14.6, y: 17.6), CGPoint(x: 20.2, y: 12), width: 1.35)

            /// Looping arrows: the classic repeat pair, one turning down on the
            /// right, one turning up on the left.
            case .repeatAll, .repeatOne:
                // A wide loop: top runs left → right and turns down, bottom runs
                // right → left and turns up, each end carrying an arrowhead.
                var upper = Path()
                upper.move(to: CGPoint(x: 5.2, y: 5.8))
                upper.addLine(to: CGPoint(x: 14.2, y: 5.8))
                upper.addArc(center: CGPoint(x: 14.2, y: 9.2),
                             radius: 3.4,
                             startAngle: .degrees(-90),
                             endAngle: .degrees(0),
                             clockwise: false)
                upper.addLine(to: CGPoint(x: 17.6, y: 11.6))
                stroke(upper, width: 1.3)
                line(CGPoint(x: 15.2, y: 10.2), CGPoint(x: 17.6, y: 14.0), width: 1.3)
                line(CGPoint(x: 20.0, y: 10.2), CGPoint(x: 17.6, y: 14.0), width: 1.3)

                var lower = Path()
                lower.move(to: CGPoint(x: 18.8, y: 18.2))
                lower.addLine(to: CGPoint(x: 9.8, y: 18.2))
                lower.addArc(center: CGPoint(x: 9.8, y: 14.8),
                             radius: 3.4,
                             startAngle: .degrees(90),
                             endAngle: .degrees(180),
                             clockwise: false)
                lower.addLine(to: CGPoint(x: 6.4, y: 12.4))
                stroke(lower, width: 1.3)
                line(CGPoint(x: 4.0, y: 14.0), CGPoint(x: 6.4, y: 10.2), width: 1.3)
                line(CGPoint(x: 8.8, y: 14.0), CGPoint(x: 6.4, y: 10.2), width: 1.3)

                if glyph == .repeatOne {
                    // The "1" that turns the loop into a single-track loop.
                    line(CGPoint(x: 12.0, y: 9.0), CGPoint(x: 12.0, y: 15.2), width: 1.45)
                    line(CGPoint(x: 10.2, y: 10.6), CGPoint(x: 12.0, y: 9.0), width: 1.25)
                }
            }
        }
    }
}
