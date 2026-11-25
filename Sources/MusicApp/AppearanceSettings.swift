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
    }

    private func bump() { revision &+= 1 }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
