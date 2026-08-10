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
                    NSApp.sendAction(
                        #selector(ScrollbackTextView.copyWithFormatting(_:)),
                        to: nil,
                        from: nil
                    )
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }

    /// Sends a finder action down the responder chain.
    ///
    /// `performTextFinderAction(_:)` reads the *sender's* tag, which is why this builds a
    /// menu item to carry it rather than passing the action along. Sending to `nil` is what
    /// makes it reach the key window's text view without this knowing which one that is.
    private static func perform(_ action: NSTextFinder.Action) {
        let carrier = NSMenuItem()
        carrier.tag = action.rawValue
        NSApp.sendAction(
            #selector(NSTextView.performTextFinderAction(_:)),
            to: nil,
            from: carrier
        )
    }
}
