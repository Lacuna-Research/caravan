import AppKit
import SwiftUI

/// Find-in-buffer, and the way across to the log.
///
/// **⌘F is the window, always.** The buffer holds `chat.scrollback-lines`; the log holds
/// everything. A find that sometimes widened to the log would be a find that sometimes
/// returns lines you cannot see, which is worse than one with a stated scope — so the scope
/// is stated, and the other one is a separate item next to it with its own name and key.
///
/// The searching itself is `NSTextFinder`'s, reached through the responder chain: every
/// scrollback is an `NSTextView` with `usesFindBar`, so ⌘F, ⌘G, ⇧⌘G and ⌘E all land on
/// whichever one is key — including in a detached window, which is the case a hand-rolled
/// find bar would have had to be told about.
public struct FindCommands: Commands {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Section {
                Button("Find…") { Self.perform(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { Self.perform(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { Self.perform(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { Self.perform(.setSearchString) }
                    .keyboardShortcut("e", modifiers: .command)

                // The way across that prompt 12's note asked for: same menu, named scope,
                // one keystroke apart, seeded with whatever ⌘F was looking for.
                Button("Find in Log…") { model.showLogSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.canSearchLog)
            }

            Section {
                // Plain text is what ⌘C gives — see `ScrollbackTextView.copy(_:)` for why —
                // so the styled version needs a name and a key of its own.
                Button("Copy with Colours") {
                    Self.scrollbackInKeyWindow()?.copyWithFormatting(nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }

    private static func perform(_ action: NSTextFinder.Action) {
        scrollbackInKeyWindow()?.perform(finderAction: action)
    }

    /// The scrollback of whichever window is in front.
    ///
    /// **Not `NSApp.sendAction(to: nil)`.** A responder-chain send reaches "whatever has
    /// focus", and what has focus when somebody reaches for ⌘F is the input box they were
    /// typing in, or the window itself after they clicked a row in the tree — never the
    /// transcript, unless they happened to click it. The live run pressed ⌘F on a freshly
    /// opened channel and got nothing at all. Asking the key window for its scrollback makes
    /// the shortcut work from wherever the user actually is, including in a detached window,
    /// which is simply the key window instead — and it settles what ⌘F searches: the
    /// transcript, never the input box.
    static func scrollbackInKeyWindow() -> ScrollbackTextView? {
        guard let root = NSApp.keyWindow?.contentView else { return nil }
        var stack = [root]
        while let view = stack.popLast() {
            if let scrollback = view as? ScrollbackTextView { return scrollback }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}
