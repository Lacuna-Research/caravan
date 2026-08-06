import AppKit
import IRCFormat
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

    /// What Tab has to choose from, asked at the moment Tab is pressed rather than held:
    /// a nick list captured when the view was built would complete against whoever was in
    /// the channel a minute ago.
    var sources: () -> CompletionSources = { CompletionSources() }

    /// The colours the box draws its own formatting codes in — the buffer's palette, so
    /// what you are writing looks like what you are about to send.
    var palette: Palette = Palette()

    /// What a completed nick is followed by.
    var completionStyle: CompletionStyle = CompletionStyle()

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
        textView.restyle()

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
        textView.restyle()
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
            guard let textView = notification.object as? InputTextView else { return }
            textView.restyle()
            field.text = textView.string
            field.onEdited()
            // Any edit that is not a Tab ends the cycle: the completion stands as typed
            // and stops being replaceable, which is what "anything else commits" means.
            if !textView.isCompleting { textView.completion.commit() }
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

    /// The cycle Tab is stepping through, if any.
    let completion = TabCompletion()

    /// Whether the edit currently being reported came from Tab.
    ///
    /// `textDidChange` cannot otherwise tell a completion from a keystroke, and it has to:
    /// a keystroke ends the cycle, and a completion is the cycle.
    private(set) var isCompleting = false

    /// The colour strip, while it is up. Held so it can be put away again, and so a
    /// second Ctrl+K does not stack one behind the other.
    private var colourPopover: NSPopover?

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
        // Draws `^B` and friends as AppKit's own control pictures. The alternative is an
        // invisible character in an editable box: a caret that moves without visible
        // cause and a Backspace that appears to delete nothing.
        layoutManager?.showsControlCharacters = true
    }

    // MARK: - Formatting codes

    /// The chords mIRC has used for thirty years, and the code each one writes.
    ///
    /// **Keyed on the letter, and read from `keyDown`, because `doCommand(by:)` cannot
    /// tell these apart.** Ctrl+I *is* Tab — same character, and it arrives as
    /// `insertTab:` — while Ctrl+B and Ctrl+K arrive as `moveBackward:` and
    /// `deleteToEndOfParagraph:`, the Emacs bindings AppKit ships. Only the unmodified
    /// character distinguishes them, and only `keyDown` still has it.
    ///
    /// Taking those bindings is the deliberate trade: this is an IRC input box, and
    /// Ctrl+B meaning bold is the older and stronger muscle memory here.
    static let chords: [Character: Character] = [
        "b": IRCFormatting.bold,
        "i": IRCFormatting.italic,
        "u": IRCFormatting.underline,
        "k": IRCFormatting.colour,
        // Not in the prompt's list of four, but in mIRC's, and the pair that makes the
        // others usable: without a reset you cannot stop, and reverse has no other way in.
        "o": IRCFormatting.reset,
        "r": IRCFormatting.reverse,
    ]

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control),
            !event.modifierFlags.contains(.command),
            let letter = event.charactersIgnoringModifiers?.lowercased().first,
            let code = Self.chords[letter]
        else {
            super.keyDown(with: event)
            return
        }
        insertText(String(code), replacementRange: selectedRange())
        // Ctrl+K alone opens the strip; with digits typed after it, those are the index,
        // which is mIRC's behaviour and what muscle memory expects. The strip does not
        // block that — it inserts digits at the same caret, or it is dismissed.
        if code == IRCFormatting.colour { showColourStrip() }
    }

    /// Opens the colour strip at the caret.
    ///
    /// **The code is inserted whether or not the strip appears.** `NSPopover` raises
    /// rather than declines when the view it is given has no window, so a Ctrl+K in a box
    /// that is not on screen would take the app down; typing the index by hand still
    /// works without it, which makes skipping the strip the harmless half to lose.
    private func showColourStrip() {
        guard window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ColourStrip { [weak self] index in
                self?.insertColourIndex(index)
            }
        )
        colourPopover = popover
        popover.show(relativeTo: caretRect(), of: self, preferredEdge: .maxY)
    }

    /// Puts the strip away.
    ///
    /// **Every edit dismisses it, and `.transient` is not enough on its own.** A transient
    /// popover closes when the user interacts *outside* it, and a keystroke aimed at the
    /// box behind it does not count — so the strip sat there while the digits were typed,
    /// which is precisely the case it exists to support. Found in the live run: the strip
    /// was still open several keystrokes later, and the next Ctrl+K only closed it.
    private func dismissColourStrip() {
        colourPopover?.close()
        colourPopover = nil
    }

    /// Every change to the text puts the strip away — including the `^C` that opened it,
    /// which is inserted before the strip is shown and so cannot dismiss its own strip.
    override func didChangeText() {
        super.didChangeText()
        dismissColourStrip()
    }

    /// Writes a palette index as **two digits**, and closes the strip.
    ///
    /// Two, always: `^C4` followed by a message that starts with a digit reads as index
    /// 42 on the receiving client. Zero-padding is what mIRC writes for the same reason,
    /// and it costs one character to be unambiguous.
    private func insertColourIndex(_ index: Int) {
        insertText(String(format: "%02d", index), replacementRange: selectedRange())
        dismissColourStrip()
    }

    /// Where the caret is, for the strip to point at. The whole box if that cannot be
    /// worked out, which still puts the strip in the right place to a pixel or two.
    private func caretRect() -> NSRect {
        guard let layoutManager, let textContainer else { return bounds }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: selectedRange().location, length: 0),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect.isEmpty ? bounds : rect
    }

    /// Redraws the box's own text with the formatting its codes ask for.
    func restyle() {
        guard let textStorage, let font else { return }
        InputStyling.apply(
            to: textStorage,
            font: font,
            palette: coordinator?.field.palette ?? Palette()
        )
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

        case #selector(insertTab(_:)):
            // Nothing to complete falls through to super, which inserts a tab. That is
            // the honest outcome: Tab in a box with no candidates is still a keystroke.
            if !complete(backwards: false) { super.doCommand(by: selector) }

        case #selector(insertBacktab(_:)):
            if !complete(backwards: true) { super.doCommand(by: selector) }

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

    /// One Tab's worth of completion. Returns whether it did anything.
    ///
    /// Goes through `insertText` rather than assigning `string` so the edit joins the
    /// undo stack and the box behaves like a text box — ⌘Z after a Tab takes the
    /// completion back rather than emptying the line.
    private func complete(backwards: Bool) -> Bool {
        guard let field = coordinator?.field else { return false }
        let caret = (string as NSString).substring(to: selectedRange().location).count
        guard
            let completed = completion.complete(
                text: string,
                caret: caret,
                sources: field.sources(),
                style: field.completionStyle,
                backwards: backwards
            )
        else { return false }

        isCompleting = true
        defer { isCompleting = false }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        if shouldChangeText(in: whole, replacementString: completed.text) {
            replaceCharacters(in: whole, with: completed.text)
            didChangeText()
        }
        let offset =
            (completed.text as NSString).length
            - (String(completed.text.dropFirst(completed.caret)) as NSString).length
        setSelectedRange(NSRange(location: offset, length: 0))
        return true
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

extension InputTextView: NSPopoverDelegate {
    /// Lets go of the strip when it dismisses itself, which a transient popover does on
    /// the first keystroke after it opens — and typing the digits *is* the first
    /// keystroke, so this is the common path rather than an edge case.
    func popoverDidClose(_ notification: Notification) {
        colourPopover = nil
    }
}
