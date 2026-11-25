import SwiftUI
import AppKit

// MARK: - Color helpers

extension Color {
    /// 0xRRGGBB
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Set while `--render-ui` draws the window through `ImageRenderer`. Lazy stacks
/// and native text fields need a real window, so the render path swaps them for
/// eager equivalents.
enum RenderMode {
    @MainActor static var isOffscreen = false
}

// MARK: - Theme (sampled from the reference screenshot)

/// The colours measured off the reference screenshot. Views never read these
/// surfaces directly — they go through `EnvironmentValues.palette`, which the
/// cover-derived `Palette` overrides at runtime; `Palette.reference` is built
/// from these values, so this is the single place the sampled colours live.
enum Theme {
    // Surfaces
    static let windowBG      = Color(hex: 0x1C2E42)   // top bar / base
    static let rowBG         = Color(hex: 0x1D2F45)   // track rows
    static let columnHeader  = Color(hex: 0x2C3D4E)   // column header strip
    static let albumHeaderBG = Color(hex: 0x223549)   // album group header
    static let selection     = Color(hex: 0x0C5693)   // selected row / active sidebar item
    static let panelBG       = Color(hex: 0x15273B)   // now playing panel
    static let transportBG   = Color(hex: 0x1B2E44)
    static let separator     = Color(hex: 0x142335)
    static let controlBG     = Color(hex: 0x2B3D52)

    // Text
    static let text          = Color(hex: 0xF4F7FB)
    static let textStrong    = Color(white: 1.0)
    static let textSecondary = Color(hex: 0x93A4B8)
    static let textDim       = Color(hex: 0x6B7F96)

    // Accents
    static let accent        = Color(hex: 0x2E86D6)
    static let starOff       = Color(hex: 0x5C7288)
    static let checkboxEdge  = Color(hex: 0x44586E)
    static let sliderTrack   = Color(hex: 0x2C4A63)
    static let sliderFill    = Color(hex: 0x1E5E9D)
}

// MARK: - Metrics (points; window is 1148 x 737 in the reference)

enum Metrics {
    static let windowWidth: CGFloat   = 1148
    static let windowHeight: CGFloat  = 737

    static let topBarHeight: CGFloat   = 52
    static let headerRowHeight: CGFloat = 26
    static let rowHeight: CGFloat      = 35
    static let sidebarWidth: CGFloat   = 160
    static let panelWidth: CGFloat     = 257
    static let transportHeight: CGFloat = 67
    static let coverThumb: CGFloat     = 62

    // Table column widths (after the leading status strip)
    static let colCheck: CGFloat      = 19
    static let colStatus: CGFloat     = 78
    static let colGenreMin: CGFloat   = 92
}

// MARK: - Typography

enum Typo {
    /// foobox draws every label in this face (theme.fth stores the name), and the
    /// reference screenshot's glyphs are unmistakably it — including the Latin
    /// and the numerals. Falls back to the system font when it is not installed.
    static let family = "HarmonyOS Sans SC"

    static let isCustomFamilyAvailable: Bool = NSFont(name: family, size: 13) != nil

    static func face(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        isCustomFamilyAvailable
            ? .custom(family, size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    static let row        = face(13)
    static let rowNumber  = face(13).monospacedDigit()
    static let header     = face(13, .semibold)
    static let albumTitle = face(15)
    static let albumMeta  = face(13)
    static let sidebar    = face(13, .medium)
    static let panelTitle = face(12.5, .semibold)
    static let panelMeta  = face(12.5)
    static let lyrics     = face(10.5)
    static let time       = face(11.5).monospacedDigit()
}

// MARK: - Reusable bits

/// 1px hairline used between rows / columns.
struct Hairline: View {
    @Environment(\.palette) private var palette
    var color: Color? = nil
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(color ?? palette.separator)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Row underline. Same pixels as `Hairline()` but without reading the palette
/// through the environment again — this one is instantiated once per row, ~10
/// times per frame while scrolling.
struct RowSeparator: View {
    /// Passed in rather than read from the environment: the row already has the
    /// palette, and this view is instantiated for every row on screen.
    var color: Color

    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

/// A checkbox as drawn in the reference: a translucent rounded square.
struct StatusCheckbox: View {
@Environment(\.palette) private var palette
    var checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(palette.controlBG.opacity(checked ? 0 : 0.55))
            .frame(width: 13, height: 13)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Theme.checkboxEdge.opacity(checked ? 1 : 0.8), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .opacity(checked ? 1 : 0)
            )
    }
}
