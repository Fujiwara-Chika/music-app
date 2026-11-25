import Foundation
import CoreGraphics

// Post a mouse click at a global (top-left origin) point, for UI smoke tests.
// usage: tools/click <x> <y> [--double]

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    print("usage: click <x> <y> [--double]")
    exit(1)
}
let point = CGPoint(x: x, y: y)
let double = args.contains("--double")

func post(_ type: CGEventType, clicks: Int64) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.post(tap: .cghidEventTap)
}

/// `--drag dx,dy` presses at the point, moves by (dx, dy) and releases — enough
/// to exercise the window's drag handle.
if let dragIndex = args.firstIndex(of: "--drag"), args.count > dragIndex + 1 {
    let parts = args[dragIndex + 1].split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else { print("usage: --drag dx,dy"); exit(1) }
    if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                          mouseCursorPosition: point, mouseButton: .left) {
        move.post(tap: .cghidEventTap)
    }
    usleep(150_000)
    post(.leftMouseDown, clicks: 1)
    let slow = args.contains("--slow")
    let steps = slow ? 40 : 12
    for i in 1...steps {
        let p = CGPoint(x: point.x + parts[0] * Double(i) / Double(steps),
                        y: point.y + parts[1] * Double(i) / Double(steps))
        if let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                              mouseCursorPosition: p, mouseButton: .left) {
            // SwiftUI gestures read the per-event delta, not just the position.
            move.setIntegerValueField(.mouseEventDeltaX,
                                      value: Int64((parts[0] / Double(steps)).rounded()))
            move.setIntegerValueField(.mouseEventDeltaY,
                                      value: Int64((parts[1] / Double(steps)).rounded()))
            move.post(tap: .cghidEventTap)
        }
        usleep(slow ? 60_000 : 12_000)
    }
    post(.leftMouseUp, clicks: 1)
    print("dragged \(parts[0]),\(parts[1])")
    exit(0)
}

post(.mouseMoved, clicks: 1)
if args.contains("--move") {
    print("moved to \(x),\(y)")
    exit(0)
}
usleep(120_000)
post(.leftMouseDown, clicks: 1)
// `--hold` keeps the button down so a menu can be captured while it is open.
if let holdIndex = args.firstIndex(of: "--hold"), args.count > holdIndex + 1,
   let milliseconds = UInt32(args[holdIndex + 1]) {
    usleep(milliseconds * 1_000)
}
usleep(40_000)
post(.leftMouseUp, clicks: 1)
if double {
    usleep(60_000)
    post(.leftMouseDown, clicks: 2)
    usleep(40_000)
    post(.leftMouseUp, clicks: 2)
}
print("clicked \(x),\(y)\(double ? " (double)" : "")")
