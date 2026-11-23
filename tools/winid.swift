import Foundation
import CoreGraphics

// Prints "number width height layer" for every window of the given owner
// process name, largest first. Callers pick the first line (the main window).
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Music"
let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
var found: [(Int, Double, Double, Int, Double, Double)] = []
for window in list {
    guard let name = window[kCGWindowOwnerName as String] as? String, name == owner else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    found.append((number, bounds["Width"] ?? 0, bounds["Height"] ?? 0, layer, bounds["X"] ?? 0, bounds["Y"] ?? 0))
}
found.sort { $0.1 * $0.2 > $1.1 * $1.2 }
for (number, width, height, layer, x, y) in found {
    print("\(number) \(Int(width)) \(Int(height)) \(layer) \(Int(x)) \(Int(y))")
}
