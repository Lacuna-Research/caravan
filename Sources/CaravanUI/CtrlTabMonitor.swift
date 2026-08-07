import AppKit
import SwiftUI

/// Watches for Ctrl+Tab, and for Ctrl coming back up.
///
/// **An `NSEvent` monitor rather than a `keyboardShortcut`, and it has to be.** SwiftUI
/// can bind a key *press*; the Windows Alt-Tab model §9 asks for turns on the modifier
/// being *released* — that is what commits the walk and what makes "hold and keep tapping"
/// different from "tap twice". There is no SwiftUI expression of a modifier release.
///
/// Tab is also a focus-navigation key that AppKit consumes before any responder sees it,
/// so a local `keyDown` monitor is the only place to catch `⌃⇥` reliably.
///
/// Scoped to key-down and flags-changed on this app's own events only. It is a *local*
/// monitor: nothing here observes other applications, and no accessibility permission is
/// asked for or needed.
@MainActor
final class CtrlTabMonitor {
    private var keyDown: Any?
    private var flagsChanged: Any?

    /// Tab's virtual key code. `keyCode` rather than the character, because with Ctrl held
    /// the character AppKit reports is not reliably a tab.
    private static let tabKeyCode: UInt16 = 48

    func start(model: AppModel) {
        stop()
        keyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.tabKeyCode,
                event.modifierFlags.contains(.control),
                // ⌃⌘⇥ and friends belong to the system and to other features.
                !event.modifierFlags.contains(.command),
                !event.modifierFlags.contains(.option)
            else { return event }
            MainActor.assumeIsolated {
                model.cycleMRU(backwards: event.modifierFlags.contains(.shift))
            }
            // Swallowed: letting it through would also move the focus ring.
            return nil
        }
        flagsChanged = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard !event.modifierFlags.contains(.control) else { return event }
            MainActor.assumeIsolated { model.endMRUCycle() }
            return event
        }
    }

    func stop() {
        for monitor in [keyDown, flagsChanged].compactMap(\.self) {
            NSEvent.removeMonitor(monitor)
        }
        keyDown = nil
        flagsChanged = nil
    }

    // No `deinit`: `NSEvent.removeMonitor` is main-thread-only and a `deinit` is not
    // isolated, so it cannot even read the handles. `stop()` is called from
    // `onDisappear`, which is the lifetime that actually matters — the monitor is
    // installed for as long as the window is on screen.
}

/// Installs the monitor for as long as the view is on screen.
struct CtrlTabModifier: ViewModifier {
    let model: AppModel

    @State private var monitor = CtrlTabMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.start(model: model) }
            .onDisappear { monitor.stop() }
    }
}
