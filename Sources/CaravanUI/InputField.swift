import AppKit
import SwiftUI

/// The input box: one line that grows, Enter to send, and a paste that never sends.
///
/// An `NSTextView` rather than SwiftUI's `TextField`. Three of the four requirements are
/// out of reach otherwise — Enter and Shift+Enter meaning different things, intercepting
/// paste before the text is committed anywhere, and Up/Down being history rather than
/// caret movement.
///
/// **The paste rule is a security rule.** Pasted text lands in the box for the user to
/// see and `Enter` is the only thing that sends. The failure it prevents is a password or
/// a private key pasted into a channel by accident, and that content is a `PRIVMSG` body
/// — the `Redactor` cannot help, because it only knows the credential-bearing commands.
/// Pre-send visibility is the only guard that exists for this case.
struct InputField: NSViewRepresentable {
    @Binding var text: String

    /// Sends whatever is in the box. Called for `Enter`, and for nothing else.
    let onSubmit: () -> Void

    /// Step back and forward through this window's history. Return `false` when there is
    /// nowhere to go, so the caret moves instead.
    let onRecallPrevious: () -> Bool
    let onRecallNext: () -> Bool

    /// Called when the user edits the text themselves, which ends any recall in progress.
    let onEdited: () -> Void

    /// The box stops growing here and scrolls beyond it.
    private let maximumLines = 6

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InputTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.field = self
        guard let textView = scrollView.documentView as? InputTextView else { return }
        // Only when it actually differs: assigning `string` resets the selection, so an
        // unconditional write would drag the caret to the front on every keystroke.
        if textView.string != text {
            textView.string = text
            textView.moveToEndOfDocument(nil)
        }
    }

    /// Grows with the text, up to six lines.
    ///
    /// Measured from the layout manager rather than counting newlines, because a long
    /// line that wraps takes two rows and a box that ignored that would clip it.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
            let container = textView.textContainer,
            let layoutManager = textView.layoutManager,
            let font = textView.font
        else { return nil }

        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }

        let inset = textView.textContainerInset
        container.containerSize = NSSize(
            width: max(width - inset.width * 2, 1),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: container)

        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let used = layoutManager.usedRect(for: container).height
        let clamped = min(max(used, lineHeight), lineHeight * CGFloat(maximumLines))
        return CGSize(width: width, height: clamped + inset.height * 2)
    }

    /// Bridges the text view's editing callbacks back to SwiftUI.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var field: InputField
        weak var textView: InputTextView?

        init(field: InputField) {
            self.field = field
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            field.text = textView.string
            field.onEdited()
        }

        /// Replaces the box's contents and puts the caret at the end, as recalling a
        /// history entry should.
        func replaceText(with newText: String) {
            guard let textView else { return }
            textView.string = newText
            textView.moveToEndOfDocument(nil)
            field.text = newText
        }
    }
}

/// The text view itself: key handling, and the paste funnel.
@MainActor
final class InputTextView: NSTextView {
    weak var coordinator: InputField.Coordinator?

    /// The modifiers on the event being handled.
    ///
    /// A seam, and one the live run earned. In a text view that is not a field editor,
    /// **Shift+Return arrives as `insertNewline:` — exactly like Return** — so without
    /// consulting the modifier both of them send, and the multi-line box can never be
    /// built. `doCommand(by:)` does not carry the flags and `NSApp.currentEvent` is not
    /// something a test can set, so it goes through here.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    convenience init() {
        // TextKit 1 explicitly. `sizeThatFits` measures through `layoutManager`, and
        // reaching for that on a TextKit 2 view silently downgrades it anyway — better to
        // ask for the engine being used than to be given it by accident.
        self.init(usingTextLayoutManager: false)
        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 4, height: 4)
        textContainer?.widthTracksTextView = true
        font = ChatFont.nsFont()
        drawsBackground = false
    }

    // MARK: - Keys

    /// `doCommandBySelector` rather than `keyDown`: this runs *after* the input method has
    /// had the event, so `Return` still commits a composition instead of sending it.
    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            // Shift+Enter is a newline in the box, never a send — and it is the *same*
            // selector as plain Enter here, so the modifier is the only thing telling
            // them apart.
            if modifierFlags().contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                coordinator?.field.onSubmit()
            }

        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            // The bindings some keyboard layouts and key-binding files send instead.
            insertText("\n", replacementRange: selectedRange())

        case #selector(moveUp(_:)):
            // History only from the first line, so arrowing around a multi-line message
            // still works. Falls through to the caret when there is no history left.
            guard isCaretOnFirstLine, coordinator?.field.onRecallPrevious() == true else {
                super.doCommand(by: selector)
                return
            }

        case #selector(moveDown(_:)):
            guard isCaretOnLastLine, coordinator?.field.onRecallNext() == true else {
                super.doCommand(by: selector)
                return
            }

        default:
            super.doCommand(by: selector)
        }
    }

    private var isCaretOnFirstLine: Bool {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        return line.location == 0
    }

    private var isCaretOnLastLine: Bool {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        return line.location + line.length >= text.length
    }

    // MARK: - Paste

    // Every way text can arrive from outside — ⌘V, paste-and-match-style, a drag, a
    // service — goes through `readSelection(from:)` below. One funnel, because a rule
    // this load-bearing must not have a path around it.
    override func paste(_ sender: Any?) { _ = readSelection(from: .general) }
    override func pasteAsPlainText(_ sender: Any?) { _ = readSelection(from: .general) }
    override func pasteAsRichText(_ sender: Any?) { _ = readSelection(from: .general) }

    /// Inserts pasted or dropped text. **Nothing here sends.**
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let string = pboard.string(forType: .string) else {
            return super.readSelection(from: pboard)
        }
        insertText(InputTextView.sanitizePaste(string), replacementRange: selectedRange())
        return true
    }

    /// Normalizes line endings and strips *trailing* newlines.
    ///
    /// The trailing newline is the dangerous case, and it is the common one: copying a
    /// whole line from a terminal or an editor produces it routinely, and a naive handler
    /// reads it as `Enter` and sends immediately. Interior newlines are kept — a
    /// multi-line paste fills the box, and Enter then sends the lines as separate
    /// messages — but no newline anywhere in pasted content is ever a send.
    static func sanitizePaste(_ text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        while normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        return normalized
    }
}
