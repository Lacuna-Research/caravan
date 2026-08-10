import AppKit
import CaravanTestSupport
import Foundation
import Testing

@testable import CaravanUI

/// ⌘C, ⇧⌘C, and what reaches the pasteboard.
@MainActor
@Suite("Copying out of a buffer")
struct ScrollbackCopyTests {
    /// A pasteboard of this test's own. The general one belongs to whoever is at the
    /// machine, and a suite that clears it takes their clipboard away mid-run.
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("caravan.tests.\(UUID().uuidString)"))
    }

    private func textView(_ styled: NSAttributedString) -> ScrollbackTextView {
        let view = ScrollbackTextView(usingTextLayoutManager: false)
        view.isRichText = true
        view.textStorage?.setAttributedString(styled)
        return view
    }

    private func coloured() -> NSAttributedString {
        NSMutableAttributedString(
            string: "[12:00:00] <bob> hello",
            attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 13)]
        )
    }

    /// **The departure from the platform default, asserted.** `NSTextView` writes RTF and
    /// plain together; a palette built for a dark window then lands as pale grey on white.
    @Test("⌘C puts plain text on the pasteboard, and nothing else")
    func copyIsPlain() {
        let view = textView(coloured())
        view.setSelectedRange(NSRange(location: 0, length: view.string.count))

        let board = pasteboard()
        view.writeSelection(to: board, plainOnly: true)

        #expect(board.string(forType: .string) == "[12:00:00] <bob> hello")
        #expect(board.data(forType: .rtf) == nil, "no styling may reach it")
    }

    @Test("Copy with Colours carries the styling as well")
    func copyWithFormattingIsRich() {
        let view = textView(coloured())
        view.setSelectedRange(NSRange(location: 0, length: view.string.count))

        let board = pasteboard()
        view.writeSelection(to: board, plainOnly: false)

        #expect(board.string(forType: .string) == "[12:00:00] <bob> hello")
        #expect(board.data(forType: .rtf) != nil)
    }

    @Test("copying part of a line copies that part")
    func partialSelection() {
        let view = textView(coloured())
        view.setSelectedRange(NSRange(location: 17, length: 5))

        let board = pasteboard()
        view.writeSelection(to: board, plainOnly: true)
        #expect(board.string(forType: .string) == "hello")
    }

    @Test("with nothing selected, nothing is written")
    func emptySelection() {
        let view = textView(coloured())
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let board = pasteboard()
        board.clearContents()
        board.setString("untouched", forType: .string)
        view.writeSelection(to: board, plainOnly: true)
        #expect(board.string(forType: .string) == "untouched")
    }
}

/// The find bar over a scrollback that is still filling up.
///
/// **What is asserted here is the wiring, not the searching.** `NSTextFinder` owns the
/// matching, the highlighting and the "3 of 47", and testing those would be testing AppKit.
/// What this client is responsible for is that a finder exists on every scrollback, that it
/// survives the buffer being appended to and trimmed under it, and that an action sent down
/// the responder chain is either understood or ignored. The behaviour on screen is the live
/// run's to confirm.
@MainActor
@Suite("Finding in a buffer")
struct FindInBufferTests {
    private func scrollback() -> (MessageLogController, ScrollbackTextView) {
        let controller = MessageLogController()
        let scrollView = controller.displayView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scrollView.layoutSubtreeIfNeeded()
        let view = scrollView.documentView as! ScrollbackTextView
        return (controller, view)
    }

    /// The finder holds ranges into the string it last searched, and a busy channel invalidates
    /// them constantly: lines arrive at the bottom and are trimmed off the top.
    @Test("the buffer stays coherent while it is appended to and trimmed under a search")
    func mutationsWithAFinderAttached() {
        let (controller, view) = scrollback()
        controller.lineCap = 20

        // Open the find interface first, so the mutations below happen under a live finder
        // rather than against one that has never been built.
        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(show)

        for index in 0..<50 {
            controller.append([AttributedString("line \(index) needle")])
        }
        controller.flush()

        #expect(controller.lineCount <= 20)
        #expect(view.string.contains("needle"))
        // The trim took the early lines with it, which is the case that leaves a stale range
        // behind if the finder is not told.
        #expect(!view.string.contains("line 0 needle"))
    }

    /// A sender with no finder tag is not a finder action, and must not be guessed at.
    @Test("an unrecognised sender is ignored rather than acted on")
    func unknownActionIsIgnored() {
        let (_, view) = scrollback()
        view.performTextFinderAction(nil)
        view.performTextFinderAction(NSMenuItem())
    }

    @Test("every scrollback gets a find bar, including a detached one's")
    func everyScrollbackIsSearchable() {
        let (_, view) = scrollback()
        #expect(view.enclosingScrollView != nil, "the finder's bar container")
        #expect(view.isSelectable, "and there is something to search")
    }
}
