import SwiftUI

/// The menu-bar half of navigation at scale (GUI-DESIGN-NOTES.md §9, §11).
///
/// In the menu bar rather than as invisible key handlers, because a shortcut nobody can
/// discover is a shortcut nobody uses — and unbound-by-default ⌘1–9 (§11) already spends
/// enough discoverability. The menu is where you find out the keys exist.
///
/// Ctrl+Tab is deliberately absent: it needs the modifier's release to work the way §9
/// asks, which a menu shortcut cannot express. `CtrlTabMonitor` owns it, and the Window
/// menu item below says so.
public struct NavigationCommands: Commands {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandMenu("Navigate") {
            Button("Quick Switcher…") { model.isShowingQuickSwitcher = true }
                .keyboardShortcut("k", modifiers: .command)

            Divider()

            // **Two bindings, not one** (§9): on a busy network unread is noise and
            // highlights are not. irssi's Alt+A is the model §9 names, so ⌥⌘A is "any
            // activity" and the same key with Shift is the stronger filter — one key to
            // remember, one modifier for "only the ones addressed to me".
            //
            // **Not ⌥⌘H.** That was the first choice and the live run killed it: ⌥⌘H is
            // macOS's own Hide Others, the App menu wins, and the shortcut silently did
            // nothing. Nothing in the build reports a collision with a system shortcut.
            Button("Next Unread") { model.selectNextUnread() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!model.hasUnreadBuffer)
            Button("Next Highlight") { model.selectNextHighlight() }
                .keyboardShortcut("a", modifiers: [.command, .option, .shift])
                .disabled(!model.hasHighlightedBuffer)

            Divider()

            // ⌘1–9 exist whether or not anything is bound, so the menu can say what they
            // are for. An item with no binding is disabled rather than absent — a gap in
            // the numbering would read as a bug.
            ForEach(Array(BufferBindings.digits), id: \.self) { digit in
                Button(title(for: digit)) {
                    Task { await model.activateBinding(digit: digit) }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(digit)")),
                    modifiers: .command
                )
                .disabled(model.bindings.binding(for: digit) == nil)
            }
        }
    }

    private func title(for digit: Int) -> String {
        guard let binding = model.bindings.binding(for: digit) else {
            return "Buffer \(digit) (unbound)"
        }
        return binding.buffer.isEmpty ? binding.network : binding.buffer
    }
}
