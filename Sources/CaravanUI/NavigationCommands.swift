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
        // **Everything the toolbar can hide, the menu bar keeps** (§8). The toolbar became
        // customizable in prompt 7, so any item in it can be dragged away; prompt 4's live
        // run already found once that losing Connect makes multi-network unreachable, and
        // a customization palette must not be a way to reproduce that.
        CommandMenu("Network") {
            Button("Connect…") { model.isShowingConnectSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Disconnect") { Task { await model.disconnect() } }
                .disabled(model.activeConnection?.isConnected != true)

            Divider()

            // ⌘W was a toolbar button carrying a shortcut until prompt 7. A customizable
            // toolbar cannot hold a keyboard shortcut, because dragging the button away
            // would take the key with it.
            //
            // **Only when the main window is in front.** With a detached buffer key, ⌘W
            // means "close this window" — acting on the main window's selection would
            // close a buffer the user is not looking at.
            Button(model.closeBufferTitle ?? "Close Buffer") {
                Task { await model.closeSelectedBuffer() }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model.closeBufferTitle == nil || model.keyWindow != .main)

            Button("Close Network") {
                Task {
                    if let connection = model.activeConnection { await model.close(connection) }
                }
            }
            .disabled(model.activeConnection == nil)
        }

        CommandGroup(after: .sidebar) {
            // **One affordance, buffers and canvases alike** (§1, §10) — the same command
            // the tree's context menu and the toolbar item invoke.
            Button(detachTitle) {
                guard let selection = model.selection else { return }
                if model.isDetached(selection) {
                    model.reattach(selection)
                } else {
                    model.detachSelected()
                }
            }
            // **Not ⌃⌘D.** That was the obvious mnemonic for "detach" and the live run
            // killed it: ⌃⌘D is macOS's system-wide "Look Up in Dictionary" text service,
            // which swallows it before any menu sees it. The menu item showed the shortcut
            // correctly and simply never fired — the second time this stage has been caught
            // by a system shortcut that reports no conflict at build time.
            .keyboardShortcut("o", modifiers: [.command, .control])
            .disabled(model.selection == nil)

            // Also a toolbar item, and therefore droppable from the toolbar — so it lives
            // here as well. A detached channel window has no toolbar item for it at all.
            Button(
                model.settings.isNickListVisible ? "Hide Nick List" : "Show Nick List"
            ) {
                model.settings.isNickListVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            Divider()
        }

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

    private var detachTitle: String {
        guard let selection = model.selection, model.isDetached(selection) else {
            return "Open in New Window"
        }
        return "Bring Back Into Main Window"
    }

    private func title(for digit: Int) -> String {
        guard let binding = model.bindings.binding(for: digit) else {
            return "Buffer \(digit) (unbound)"
        }
        return binding.buffer.isEmpty ? binding.network : binding.buffer
    }
}
