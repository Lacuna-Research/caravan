import AppKit
import IRCFormat
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

        /// What Tab completes against. Settable so a test can say who is in the channel.
        var sources = CompletionSources()

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
                sources: { [weak self] in self?.sources ?? CompletionSources() },
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

        /// Tab, or Shift+Tab. The selectors AppKit sends for each.
        func pressTab(shift: Bool = false) {
            press(
                shift
                    ? #selector(NSTextView.insertBacktab(_:))
                    : #selector(NSTextView.insertTab(_:))
            )
        }

        /// A Ctrl chord, as `keyDown` receives it.
        ///
        /// Through a real `NSEvent` rather than by calling the handler: the whole reason
        /// these are read in `keyDown` is that `doCommand(by:)` cannot tell Ctrl+I from
        /// Tab, and a test that bypassed the event would not be testing that.
        func chord(_ letter: String) {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: letter,
                charactersIgnoringModifiers: letter,
                isARepeat: false,
                keyCode: 0
            )
            guard let event else { return }
            textView.keyDown(with: event)
        }

        var text: String { textView.string }

        var caret: Int { textView.selectedRange().location }
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
        // Obviously fake, per CLAUDE.md: a fixture shaped like a real credential is one
        // the secret scanner has to flag, and it is right to.
        harness.paste("s3cr3t-not-real\n")
        #expect(harness.sent.isEmpty)
        #expect(harness.text == "s3cr3t-not-real")
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

    // MARK: - Formatting chords

    /// Read from `keyDown` rather than `doCommand(by:)`, because AppKit cannot tell these
    /// apart there: Ctrl+I *is* Tab, and Ctrl+B and Ctrl+K are the Emacs editing bindings.
    @Test("the mIRC chords insert the codes the parser reads")
    func chordsInsertCodes() {
        let harness = Harness()
        harness.chord("b")
        harness.type("loud")
        harness.chord("b")
        #expect(harness.text == "\u{02}loud\u{02}")

        for (letter, code) in [
            ("i", IRCFormatting.italic),
            ("u", IRCFormatting.underline),
            ("o", IRCFormatting.reset),
            ("r", IRCFormatting.reverse),
        ] {
            let box = Harness()
            box.chord(letter)
            #expect(box.text == String(code), "Ctrl+\(letter) writes its own code")
        }
    }

    /// Ctrl+I must not fall through to Tab, and Tab must not insert an italic code.
    @Test("Ctrl+I is italic while Tab is completion")
    func ctrlIIsNotTab() {
        let harness = Harness()
        harness.sources = CompletionSources(nicks: ["alice"])
        harness.chord("i")
        #expect(harness.text == String(IRCFormatting.italic))

        let completing = Harness()
        completing.sources = CompletionSources(nicks: ["alice"])
        completing.type("ali")
        completing.pressTab()
        #expect(completing.text == "alice: ")
        #expect(!completing.text.contains(IRCFormatting.italic))
    }

    @Test("Ctrl+K writes the colour code, and typed digits are the index")
    func colourChord() {
        let harness = Harness()
        harness.chord("k")
        harness.type("04red")
        #expect(harness.text == "\u{03}04red")
        // What the parser makes of it is the only thing that matters here.
        let parsed = IRCFormatting.parse(harness.text)
        #expect(parsed.plain == "red")
        #expect(parsed.runs.first?.style.foreground == .indexed(4))
    }

    // MARK: - Tab, through the real keys

    @Test("Tab completes and repeated Tab cycles, in the box")
    func tabCyclesInTheBox() {
        let harness = Harness()
        harness.sources = CompletionSources(nicks: ["Bob", "bobby"])
        harness.type("bo")
        harness.pressTab()
        #expect(harness.text == "Bob: ")
        #expect(harness.caret == 5, "the caret follows the completion")

        harness.pressTab()
        #expect(harness.text == "bobby: ")

        harness.pressTab(shift: true)
        #expect(harness.text == "Bob: ", "Shift+Tab steps back")
    }

    /// "Anything else commits": typing after a completion leaves it standing, and the
    /// next Tab starts a new word rather than rewriting the old one.
    @Test("typing after a completion commits it")
    func typingCommits() {
        let harness = Harness()
        harness.sources = CompletionSources(nicks: ["Bob", "bobby"])
        harness.type("bo")
        harness.pressTab()
        harness.type("hi ca")
        #expect(harness.text == "Bob: hi ca")

        harness.sources = CompletionSources(nicks: ["Bob", "bobby", "carol"])
        harness.pressTab()
        #expect(harness.text == "Bob: hi carol ")
    }

    /// Tab with nothing to complete is still a keystroke — it must not silently vanish.
    @Test("Tab with no candidates falls through to the text view")
    func tabFallsThrough() {
        let harness = Harness()
        harness.type("zzz")
        harness.pressTab()
        #expect(harness.text.hasPrefix("zzz"))
        #expect(harness.text != "zzz: ")
    }

    // MARK: - The box draws what it will send

    /// **Asserted on the text storage, not on an `AttributedString`.** Prompt 1 lost every
    /// colour and underline at exactly this crossing, twice, and both times the value on
    /// the way in was correct.
    @Test("the box styles its own text, and shows the codes rather than hiding them")
    func previewStylesTheStorage() throws {
        let harness = Harness()
        harness.chord("b")
        harness.type("loud")
        harness.chord("b")
        harness.type(" \u{03}04red")
        harness.textView.restyle()

        let storage = try #require(harness.textView.textStorage)
        let text = storage.string
        #expect(text.contains(IRCFormatting.bold), "the code stays in the text that will be sent")

        let loud = try #require(text.range(of: "loud"))
        let boldAt = text.distance(from: text.startIndex, to: loud.lowerBound)
        let font = storage.attribute(.font, at: boldAt, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let red = try #require(text.range(of: "red"))
        let redAt = text.distance(from: text.startIndex, to: red.lowerBound)
        let colour = storage.attribute(.foregroundColor, at: redAt, effectiveRange: nil)
        #expect(colour as? NSColor != nil, "the colour code paints the text after it")
        #expect(colour as? NSColor != NSColor.labelColor)

        // The code characters themselves are dimmed, including `^C`'s digits — they are
        // part of the code, not text somebody meant to send.
        let codeAt = text.distance(
            from: text.startIndex,
            to: try #require(text.firstIndex(of: "\u{03}"))
        )
        let codeColour = storage.attribute(.foregroundColor, at: codeAt, effectiveRange: nil)
        #expect(codeColour as? NSColor == NSColor.tertiaryLabelColor)
        let digitColour = storage.attribute(.foregroundColor, at: codeAt + 1, effectiveRange: nil)
        #expect(
            digitColour as? NSColor == NSColor.tertiaryLabelColor,
            "the digits are the code too"
        )
    }

    /// A code deleted has to stop styling the text that followed it.
    @Test("restyling is idempotent, so deleting a code clears its styling")
    func restyleClears() throws {
        let harness = Harness()
        harness.chord("b")
        harness.type("loud")
        harness.textView.restyle()

        harness.textView.string = "loud"
        harness.textView.restyle()
        let storage = try #require(harness.textView.textStorage)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }
}
