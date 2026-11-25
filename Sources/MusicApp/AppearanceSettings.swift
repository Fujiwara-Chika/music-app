import SwiftUI
import AppKit

/// Window backdrop preferences: how much of the blurred artwork behind the
/// content shows through, and how blurred it is.
@MainActor
final class AppearanceSettings: ObservableObject {
    private enum Key {
        static let opacity = "appearance.backgroundOpacity"
        static let blur = "appearance.backgroundBlur"
        static let backdrop = "appearance.artworkBackdrop"
        static let sidebar = "layout.sidebarWidth"
        static let panel = "layout.panelWidth"
        static let columns = "layout.columnWidths"
    }

    static let opacityRange: ClosedRange<Double> = 0.4...1.0
    static let blurRange: ClosedRange<Double> = 0...80

    /// 1.0 means "solid, exactly like before" — the slider only ever removes
    /// opacity, so the default keeps the reference look.
    @Published var backgroundOpacity: Double {
        didSet {
            defaults.set(backgroundOpacity, forKey: Key.opacity)
            bump()
        }
    }

    @Published var backgroundBlur: Double {
        didSet {
            defaults.set(backgroundBlur, forKey: Key.blur)
            bump()
        }
    }

    /// Blur the current cover behind the window instead of a flat wash.
    @Published var usesArtworkBackdrop: Bool {
        didSet {
            defaults.set(usesArtworkBackdrop, forKey: Key.backdrop)
            bump()
        }
    }

    /// Pane widths. Dragged by the two hairline handles; every pane keeps a
    /// minimum so the layout can never collapse into something unusable.
    static let sidebarWidthRange: ClosedRange<Double> = 140...340
    static let panelWidthRange: ClosedRange<Double> = 200...420

    @Published var sidebarWidth: Double {
        didSet {
            let clamped = Self.clamp(sidebarWidth, to: Self.sidebarWidthRange)
            if clamped != sidebarWidth { sidebarWidth = clamped; return }
            defaults.set(sidebarWidth, forKey: Key.sidebar)
            bump()
        }
    }

    @Published var panelWidth: Double {
        didSet {
            let clamped = Self.clamp(panelWidth, to: Self.panelWidthRange)
            if clamped != panelWidth { panelWidth = clamped; return }
            defaults.set(panelWidth, forKey: Key.panel)
            bump()
        }
    }

    /// Table column widths, keyed by `SongTableColumns.key`. Only columns the
    /// user has dragged are stored; everything else keeps its proportional size.
    @Published var columnWidths: [String: Double] {
        didSet {
            defaults.set(columnWidths, forKey: Key.columns)
            bump()
        }
    }

    func setColumnWidth(_ width: Double, for key: String) {
        guard let minimum = SongTableColumns.minimums[key] else { return }
        var next = columnWidths
        next[key] = max(minimum, width)
        columnWidths = next
    }

    /// Views read this to redraw when a slider moves.
    @Published private(set) var revision = 0

    private let defaults = UserDefaults.standard

    init() {
        backgroundOpacity = Self.clamp(
            defaults.object(forKey: Key.opacity) as? Double ?? 0.94,
            to: Self.opacityRange
        )
        backgroundBlur = Self.clamp(
            defaults.object(forKey: Key.blur) as? Double ?? 26,
            to: Self.blurRange
        )
        usesArtworkBackdrop = defaults.object(forKey: Key.backdrop) as? Bool ?? true
        sidebarWidth = Self.clamp(
            defaults.object(forKey: Key.sidebar) as? Double ?? Metrics.sidebarWidth,
            to: Self.sidebarWidthRange
        )
        panelWidth = Self.clamp(
            defaults.object(forKey: Key.panel) as? Double ?? Metrics.panelWidth,
            to: Self.panelWidthRange
        )
        columnWidths = defaults.object(forKey: Key.columns) as? [String: Double] ?? [:]
    }

    /// Launch overrides, so screenshots of a given setting are reproducible:
    /// `--opacity 0.8 --blur 50`.
    func applyLaunchOverrides() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--opacity"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            backgroundOpacity = Self.clamp(value, to: Self.opacityRange)
        }
        if let index = arguments.firstIndex(of: "--blur"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            backgroundBlur = Self.clamp(value, to: Self.blurRange)
        }
        if let index = arguments.firstIndex(of: "--sidebar-width"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            sidebarWidth = Self.clamp(value, to: Self.sidebarWidthRange)
        }
        if let index = arguments.firstIndex(of: "--panel-width"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1]) {
            panelWidth = Self.clamp(value, to: Self.panelWidthRange)
        }
        if let index = arguments.firstIndex(of: "--column-widths"), index + 1 < arguments.count {
            for pair in arguments[index + 1].split(separator: ",") {
                let parts = pair.split(separator: "=")
                guard parts.count == 2, let value = Double(parts[1]) else { continue }
                setColumnWidth(value, for: String(parts[0]))
            }
        }
    }

    private func bump() { revision &+= 1 }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
