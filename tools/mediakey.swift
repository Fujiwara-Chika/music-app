import AppKit
import Foundation

// Posts a hardware media key (the F7/F8/F9 keys, the ones Control Center and the
// keyboard send) so the system's "now playing" routing can be exercised without
// a physical keyboard. usage: tools/mediakey play|next|previous|fast|rewind
let names: [String: Int] = ["play": 16, "next": 17, "previous": 18, "fast": 19, "rewind": 20]
let args = CommandLine.arguments
guard args.count > 1, let code = names[args[1]] else {
    print("usage: mediakey play|next|previous|fast|rewind")
    exit(1)
}

// subtype 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS; data1 carries the key in the high
// half and 0x0A/0x0B (down/up) in the low half.
for state in [0x0A, 0x0B] {
    let data1 = (code << 16) | (state << 8)
    guard let event = NSEvent.otherEvent(with: .systemDefined,
                                         location: .zero,
                                         modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: 0,
                                         context: nil,
                                         subtype: 8,
                                         data1: data1,
                                         data2: -1) else {
        print("could not build the event")
        exit(1)
    }
    event.cgEvent?.post(tap: .cghidEventTap)
    usleep(30_000)
}
print("media key \(args[1]) sent")
