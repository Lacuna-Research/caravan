import AppKit
import SwiftUI
import Testing

@testable import CaravanUI

/// The input box, driven headlessly against a real `NSTextView`.
///
/// The paste rules here are a security requirement, not a UX preference: the failure they
/// prevent is a password or a private key pasted into a channel by accident, and that
/// content is a `PRIVMSG` body — the `Redactor` cannot help, because it only knows the
/// credential-bearing commands. Pre-send visibility is the only guard that exists for it,
/// which is why every one of these paths is asserted rather than argued about.
@MainActor
@Suite("Input field")
struct InputFieldTests {
    /// A text view wired up exactly as the app wires it, plus a record of every send.
    @MainActor
    private final class Harness {
        let state = InputState()
        let textView = InputTextView()
        private(set) var sent: [String] = []

        init() {
            let state = self.state
            let field = InputField(
                text: Binding(get: { state.text }, set: { state.text = $0 }),
                // What `InputBar` does on Enter: record the line, which empties the box.
                // The write back into the view stands in for the SwiftUI update that
                // would follow the binding.
                onSubmit: { [weak self] in
                    guard let self else { return }
                    sent.append(state.text)
                    state.record(state.text)
                    textView.string = state.text
                },
                onRecallPrevious: { state.recallPrevious() },
                onRecallNext: { state.recallNext() },
                onEdited: { state.noteEdited() }
            )
            let coordinator = InputField.Coordinator(field: field)
            coordinator.textView = textView
            textView.coordinator = coordinator
            textView.delegate = coordinator
        }

        /// Types text, as a keystroke would.
        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
        }

        /// Pastes, through the same funnel ⌘V uses — without touching the real clipboard.
        func paste(_ text: String) {
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("com.lacuna-research.caravan.tests")
            )
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            _ = textView.readSelection(from: pasteboard)
        }

        func press(_ selector: Selector, shift: Bool = false) {
            textView.modifierFlags = { shift ? .shift : [] }
            textView.doCommand(by: selector)
            textView.modifierFlags = { [] }
        }

        /// Return, with or without Shift. Both arrive as the same selector, which is the
        /// whole hazard.
        func pressReturn(shift: Bool = false) {
            press(#selector(NSTextView.insertNewline(_:)), shift: shift)
        }

        var text: String { textView.string }
    }

    // MARK: - Sending

    /// The regression the live run earned: in a text view that is not a field editor,
    /// Shift+Return arrives as `insertNewline:` exactly like Return. Both sent.
    @Test("Enter sends and Shift+Enter does not")
    func enterSends() {
        let harness = Harness()
        harness.type("hello")
        harness.pressReturn()
        #expect(harness.sent == ["hello"])

        harness.type("more")
        harness.pressReturn(shift: true)
        #expect(harness.sent == ["hello"], "Shift+Enter must never send")
        #expect(harness.text == "more\n")
    }

    @Test("Shift+Enter builds a multi-line message that one Enter then sends")
    func multiLine() {
        let harness = Harness()
        harness.type("first")
        harness.pressReturn(shift: true)
        harness.type("second")
        #expect(harness.sent.isEmpty)

        harness.pressReturn()
        #expect(harness.sent == ["first\nsecond"])
    }

    /// Some layouts and key-binding files send these instead. All three are a newline.
    @Test("the other newline selectors insert rather than send")
    func alternateNewlineSelectors() {
        let harness = Harness()
        harness.type("text")
        harness.press(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)))
        harness.press(#selector(NSTextView.insertLineBreak(_:)))
        #expect(harness.sent.isEmpty)
        #expect(harness.text.hasPrefix("text"))
    }

    // MARK: - Paste

    /// The whole rule, in one assertion: text arrives, nothing leaves.
    @Test("a paste never sends")
    func pasteNeverSends() {
        let harness = Harness()
        harness.paste("hunter2")
        #expect(harness.text == "hunter2")
        #expect(harness.sent.isEmpty)
    }

    /// The trap, and the common case: copying a whole line from a terminal or an editor
    /// produces a trailing newline routinely, and a naive handler reads it as Enter.
    @Test("a paste with a trailing newline sends nothing and loses the newline")
    func pasteWithTrailingNewline() {
        let harness = Harness()
        harness.paste("-----BEGIN PRIVATE KEY-----\n")
        #expect(harness.sent.isEmpty)
        #expect(harness.text == "-----BEGIN PRIVATE KEY-----")
    }

    @Test("several trailing newlines are all stripped, and CRLF is normalized")
    func pasteLineEndings() {
        #expect(InputTextView.sanitizePaste("one\n\n\n") == "one")
        #expect(InputTextView.sanitizePaste("one\r\ntwo\r\n") == "one\ntwo")
        #expect(InputTextView.sanitizePaste("one\rtwo\r") == "one\ntwo")
        #expect(InputTextView.sanitizePaste("\n") == "")
        #expect(InputTextView.sanitizePaste("plain") == "plain")
    }

    /// Interior newlines survive: a multi-line paste fills the box, and Enter then sends
    /// the lines as separate messages. Filling the box is not sending.
    @Test("a multi-line paste fills the box and still sends nothing")
    func multiLinePaste() {
        let harness = Harness()
        harness.paste("one\ntwo\nthree\n")
        #expect(harness.sent.isEmpty)
        #expect(harness.text == "one\ntwo\nthree")

        harness.pressReturn()
        #expect(harness.sent == ["one\ntwo\nthree"])
    }

    @Test("a paste into existing text lands beside it without sending")
    func pasteIntoExistingText() {
        let harness = Harness()
        harness.type("say ")
        harness.paste("this\n")
        #expect(harness.sent.isEmpty)
        #expect(harness.text == "say this")
    }

    // MARK: - History

    @Test("Up walks back through this window's history and Down returns")
    func history() {
        let harness = Harness()
        for line in ["/join #a", "hello", "/topic new"] {
            harness.state.text = line
            harness.state.record(line)
        }

        harness.press(#selector(NSTextView.moveUp(_:)))
        #expect(harness.state.text == "/topic new")
        harness.press(#selector(NSTextView.moveUp(_:)))
        #expect(harness.state.text == "hello")
        harness.press(#selector(NSTextView.moveDown(_:)))
        #expect(harness.state.text == "/topic new")
    }

    /// Arrowing away from a half-written line and back must return it, or the history is
    /// a trap rather than a convenience.
    @Test("the in-progress line survives a trip through the history")
    func historyPreservesTheLiveLine() {
        let state = InputState()
        state.record("/join #a")
        state.text = "half written"

        state.recallPrevious()
        #expect(state.text == "/join #a")
        state.recallNext()
        #expect(state.text == "half written")
    }

    @Test("history stops at the oldest entry rather than wrapping")
    func historyDoesNotWrap() {
        let state = InputState()
        state.record("only")
        #expect(state.recallPrevious())
        #expect(!state.recallPrevious())
        #expect(state.text == "only")
    }

    @Test("an immediate repeat is recorded once")
    func historyDeduplicates() {
        let state = InputState()
        state.record("/who")
        state.record("/who")
        state.record("/names")
        state.record("/who")
        #expect(state.history == ["/who", "/names", "/who"])
    }

    /// A client left open for a week must not grow without bound — the scrollback's rule,
    /// at a much smaller scale.
    @Test("history is capped, oldest first")
    func historyIsCapped() {
        let state = InputState(historyLimit: 3)
        for index in 1...5 { state.record("line \(index)") }
        #expect(state.history == ["line 3", "line 4", "line 5"])
    }

    @Test("recalling with no history does nothing and lets the caret move")
    func emptyHistory() {
        let state = InputState()
        #expect(!state.recallPrevious())
        #expect(!state.recallNext())
    }

    /// Up on a multi-line message moves the caret; it only reaches for history from the
    /// first line, or editing a pasted block would be impossible.
    @Test("Up inside a multi-line message moves the caret rather than recalling")
    func historyOnlyFromTheEdges() {
        let harness = Harness()
        harness.state.record("earlier")
        harness.paste("one\ntwo")
        harness.textView.setSelectedRange(NSRange(location: harness.text.count, length: 0))

        harness.press(#selector(NSTextView.moveUp(_:)))
        #expect(harness.text == "one\ntwo", "the text must not be replaced from the second line")
    }
}
