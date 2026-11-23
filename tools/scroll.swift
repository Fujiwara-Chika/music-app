import Foundation
import CoreGraphics

// Post scroll-wheel events at a global point, for scroll-performance smoke tests.
// usage: scroll <x> <y> <linesPerEvent> <events> [delayMs]

let args = CommandLine.arguments
guard args.count >= 5,
      let x = Double(args[1]), let y = Double(args[2]),
      let lines = Int32(args[3]), let count = Int(args[4]) else {
    print("usage: scroll <x> <y> <linesPerEvent> <events> [delayMs]")
    exit(1)
}
let delayUs = args.count >= 6 ? (useconds_t(Int(args[5])! * 1000)) : 16_000
let point = CGPoint(x: x, y: y)

if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                      mouseCursorPosition: point, mouseButton: .left) {
    move.post(tap: .cghidEventTap)
}
usleep(120_000)

for i in 0..<count {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                             wheelCount: 1, wheel1: i < count / 2 ? lines : -lines,
                             wheel2: 0, wheel3: 0) else { continue }
    event.location = point
    event.post(tap: .cghidEventTap)
    usleep(delayUs)
}
print("scrolled \(count) events at \(x),\(y)")
