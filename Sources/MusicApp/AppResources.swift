import Foundation

/// Locates the SwiftPM resource bundle inside a real `.app`.
///
/// SwiftPM's generated `Bundle.module` accessor only tries two places:
/// `<Bundle.main.bundleURL>/MusicApp_MusicApp.bundle` (i.e. next to the `.app`,
/// not inside it) and the absolute `.build/…/release/…bundle` path of the
/// machine that compiled it. Inside a packaged app neither exists, so it calls
/// `fatalError` — which is exactly what happened on a machine that never had the
/// source tree. Look in `Contents/Resources` first and keep `Bundle.module` as a
/// last resort for `swift run` / development runs.
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "MusicApp_MusicApp", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        let inside = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MusicApp_MusicApp.bundle")
        if let bundle = Bundle(url: inside) { return bundle }
        return Bundle.module
    }()

    /// The resolved location, for `--resource-check`.
    static var location: String { bundle.bundlePath }
}
