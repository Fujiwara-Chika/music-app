import SwiftUI
import AppKit

/// Window backdrop preferences: how much of the blurred artwork behind the
/// content shows through, and how blurred it is. Also holds the table's column
/// widths, which are the only part of the layout the user can drag.
///
/// The three panes themselves are fixed (`Metrics.sidebarWidth` /
/// `Metrics.panelWidth`): the reference layout is the point, and a window that
/// re-flows every time a divider moves costs more than it gives.
@MainActor
final class AppearanceSettings: ObservableObject {
    private enum Key {
        static let opacity = "appearance.backgroundOpacity"
        static let blur = "appearance.backgroundBlur"
        static let backdrop = "appearance.artworkBackdrop"
        static let columns = "layout.columnWidths"
        static let notify = "appearance.notifyOnTrackChange"
    }

    static let opacityRange: ClosedRange<Double> = 0.4...1.0
    static let blurRange: ClosedRange<Double> = 0...80

    /// 1.0 means "solid, exactly like before" — the slider only ever removes
    /// opacity, so the default keeps the reference look.
    @Published var backgroundOpacity: Double {
        didSet {
            defaults.set(backgroundOpacity, forKey: Key.opacity)
        }
    }

    @Published var backgroundBlur: Double {
        didSet {
            defaults.set(backgroundBlur, forKey: Key.blur)
        }
    }

    /// Blur the current cover behind the window instead of a flat wash.
    @Published var usesArtworkBackdrop: Bool {
        didSet {
            defaults.set(usesArtworkBackdrop, forKey: Key.backdrop)
        }
    }

    /// System banner on every track change. On by default — it is how the app
    /// behaves when the window is behind something else.
    @Published var notifyOnTrackChange: Bool {
        didSet {
            defaults.set(notifyOnTrackChange, forKey: Key.notify)
        }
    }

    /// Per-column widths, keyed by `SongTableColumns.key`. Only the four columns
    /// with a grip are ever stored; genre is the filler and takes what is left.
    ///
    /// Widths change on every drag frame, so they are held in memory and written
    /// once when the gesture ends (`commitLayout`) — sixty `UserDefaults` writes a
    /// second would buy nothing.
    @Published var columnWidths: [String: Double]

    func setColumnWidth(_ width: Double, for key: String) {
        guard let minimum = SongTableColumns.minimums[key] else { return }
        var next = columnWidths
        next[key] = max(minimum, width)
        columnWidths = next
    }

    /// Pins the four user columns at the widths they are painted at right now.
    /// A divider drag calls this on its first frame, so the drag moves only that
    /// divider — and the widths the user settled on are what a later window
    /// resize keeps.
    func materialize(_ columns: SongTableColumns) {
        var next = columnWidths
        for key in SongTableColumns.resizableKeys {
            next[key] = Double(columns.width(of: key))
        }
        columnWidths = next
    }

    /// Persists the current column widths. Called when a drag ends.
    func commitLayout() {
        defaults.set(columnWidths, forKey: Key.columns)
    }

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
        notifyOnTrackChange = defaults.object(forKey: Key.notify) as? Bool ?? true
        columnWidths = defaults.object(forKey: Key.columns) as? [String: Double] ?? [:]
    }

    /// Launch overrides, so screenshots of a given setting are reproducible:
    /// `--opacity 0.8 --blur 50 --column-widths title=190,album=160`.
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
        if let index = arguments.firstIndex(of: "--column-widths"), index + 1 < arguments.count {
            for pair in arguments[index + 1].split(separator: ",") {
                let parts = pair.split(separator: "=")
                guard parts.count == 2, let value = Double(parts[1]) else { continue }
                setColumnWidth(value, for: String(parts[0]))
            }
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
