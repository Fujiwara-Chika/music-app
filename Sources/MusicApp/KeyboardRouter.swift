@preconcurrency import AppKit

/// Keeps the keyboard pointed at the player.
///
/// The filter box is the only text input in the app, and it used to take the
/// keyboard on launch: space then typed (or fed the IME) instead of playing, and
/// the transport shortcuts went into the search field. The rules are explicit
/// now:
///
///   * space (no modifiers) is play/pause — unless a text field is being edited;
///   * Escape leaves the filter field;
///   * a click outside the filter strip releases it.
///
/// A menu item cannot carry this: AppKit's menu key equivalents do not match a
/// shortcut with an empty modifier mask, so `keyboardShortcut(.space, modifiers:
/// [])` showed the key in the menu and then did nothing. Hence the local monitor.
@MainActor
final class KeyboardRouter {
    /// What the monitor should do with an event.
    private enum Decision { case pass, consume }

    /// App-local monitors are dispatched on the main thread, and the event never
    /// leaves it; the box only says so to the compiler, which cannot know.
    private struct EventBox: @unchecked Sendable {
        let event: NSEvent
    }

    private var monitor: Any?
    private weak var player: PlayerEngine?

    func install(for player: PlayerEngine) {
        self.player = player
        guard monitor == nil else { return }
        monitor = Self.addMonitor { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            let decision = MainActor.assumeIsolated { self.route(box.event) }
            return decision == .consume ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func addMonitor(_ body: @escaping (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: body)
    }

    // MARK: - Routing

    private func route(_ event: NSEvent) -> Decision {
        if event.type == .leftMouseDown {
            releaseFilterIfClickWasOutside(event)
            return .pass
        }

        // 53 = escape, 49 = space.
        if event.keyCode == 53, isEditingText {
            NSApp.keyWindow?.makeFirstResponder(nil)
            return .consume
        }
        guard event.keyCode == 49, !event.isARepeat, !isEditingText,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        else { return .pass }

        player?.toggle()
        return .consume
    }

    /// `true` while a field editor owns the keystrokes — i.e. the user is typing
    /// into the filter, and space belongs to what they are typing.
    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let text = responder as? NSText { return text.isEditable }
        if let view = responder as? NSTextView { return view.isEditable }
        return false
    }

    /// Clicking anywhere but the filter strip means "I am done typing". Without
    /// this the field keeps the keyboard forever, because none of the surrounding
    /// controls take focus themselves.
    private func releaseFilterIfClickWasOutside(_ event: NSEvent) {
        guard isEditingText, let window = event.window else { return }
        // Window coordinates are bottom-left, and the strip is the sidebar's
        // header row: the top bar first, then `headerRowHeight` points below it.
        let strip = CGRect(x: 0,
                           y: window.frame.height - Metrics.topBarHeight - Metrics.headerRowHeight,
                           width: Metrics.sidebarWidth,
                           height: Metrics.headerRowHeight)
        if !strip.contains(event.locationInWindow) {
            window.makeFirstResponder(nil)
        }
    }
}
