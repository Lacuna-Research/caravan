import AppKit
import CaravanTestSupport
import Testing

@testable import CaravanUI

/// The scrollback engine, driven headlessly.
///
/// Real `NSTextView`s, not a fake: the behaviour worth testing — that a batch is one
/// mutation, that trimming deletes the right characters, that scroll-lock survives an
/// append — is behaviour of the text system, and a stand-in would prove nothing about it.
@MainActor
@Suite("Message log")
struct MessageLogControllerTests {
    /// A controller attached to a real, laid-out text view and scroll view.
    private func makeHarness(
        lineCap: Int = 5000,
        viewportHeight: CGFloat = 200
    ) -> (controller: MessageLogController, textView: NSTextView, scrollView: NSScrollView) {
        let controller = MessageLogController(lineCap: lineCap, coalesceInterval: .milliseconds(5))
        let textView = MessageLogView.makeTextView(usesTextKit2: true)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: viewportHeight))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        controller.attach(textView: textView, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()
        return (controller, textView, scrollView)
    }

    private func lines(_ count: Int, prefix: String = "line") -> [AttributedString] {
        (0..<count).map { AttributedString("\(prefix) \($0)") }
    }

    private func text(of textView: NSTextView) -> String {
        textView.textStorage?.string ?? ""
    }

    // MARK: - Appending

    @Test("appended lines reach the view, each on its own line")
    func appendsLines() {
        let harness = makeHarness()
        harness.controller.append(lines(3))
        harness.controller.flush()

        #expect(text(of: harness.textView) == "line 0\nline 1\nline 2\n")
        #expect(harness.controller.lineCount == 3)
    }

    /// The property that makes a MOTD burst cheap: one editing transaction however many
    /// lines arrived, not one per line.
    @Test("a flush is a single editing transaction")
    func oneMutationPerFlush() {
        let harness = makeHarness()
        let counter = EditCounter()
        harness.textView.textStorage?.delegate = counter

        harness.controller.append(lines(200))
        harness.controller.flush()

        #expect(harness.controller.lineCount == 200)
        #expect(counter.edits == 1)
    }

    @Test("appends before a flush accumulate into one batch")
    func appendsCoalesce() {
        let harness = makeHarness()
        let counter = EditCounter()
        harness.textView.textStorage?.delegate = counter

        for index in 0..<10 {
            harness.controller.append([AttributedString("line \(index)")])
        }
        harness.controller.flush()

        #expect(counter.edits == 1)
        #expect(harness.controller.lineCount == 10)
    }

    @Test("appends coalesce on the timer without an explicit flush")
    func flushesOnTimer() async throws {
        let harness = makeHarness()
        harness.controller.append(lines(5))
        #expect(harness.controller.lineCount == 0)  // Nothing applied yet.

        // Polled rather than slept: the flush lands on the main actor, and every suite in
        // this target wants the main actor too. A fixed wait passes here and fails on a
        // loaded runner, which is the least useful kind of test.
        #expect(await waitUntil { harness.controller.lineCount == 5 })
        #expect(text(of: harness.textView).hasPrefix("line 0\n"))
    }

    @Test("an empty append does nothing")
    func emptyAppend() {
        let harness = makeHarness()
        harness.controller.append([])
        harness.controller.flush()
        #expect(harness.controller.lineCount == 0)
        #expect(text(of: harness.textView).isEmpty)
    }

    // MARK: - Trimming

    /// A client left open for a week must not grow without bound.
    @Test("the buffer is trimmed to its cap, from the top")
    func trimsToCap() {
        let harness = makeHarness(lineCap: 100)
        harness.controller.append(lines(500))
        harness.controller.flush()

        #expect(harness.controller.lineCount == 100)
        // The *newest* lines survive, and the text really was deleted rather than hidden.
        let contents = text(of: harness.textView)
        #expect(contents.hasPrefix("line 400\n"))
        #expect(contents.hasSuffix("line 499\n"))
        #expect(!contents.contains("line 399\n"))
    }

    @Test("trimming leaves the remaining text intact, not truncated mid-line")
    func trimIsLineAligned() {
        let harness = makeHarness(lineCap: 10)
        harness.controller.append(lines(100, prefix: "a much longer line of text"))
        harness.controller.flush()

        let remaining = text(of: harness.textView).split(separator: "\n")
        #expect(remaining.count == 10)
        #expect(remaining.allSatisfy { $0.hasPrefix("a much longer line of text ") })
    }

    @Test("a steady stream does not trim on every flush")
    func trimHasSlack() {
        let harness = makeHarness(lineCap: 100)
        harness.controller.append(lines(100))
        harness.controller.flush()
        #expect(harness.controller.lineCount == 100)

        // Inside the slack margin: nothing is dropped yet.
        harness.controller.append(lines(5, prefix: "extra"))
        harness.controller.flush()
        #expect(harness.controller.lineCount == 105)
    }

    @Test("clear empties the view")
    func clear() {
        let harness = makeHarness()
        harness.controller.append(lines(10))
        harness.controller.flush()
        harness.controller.clear()

        #expect(harness.controller.lineCount == 0)
        #expect(text(of: harness.textView).isEmpty)
    }

    // MARK: - Scroll-lock

    @Test("a fresh log is pinned to the bottom")
    func startsPinned() {
        #expect(makeHarness().controller.isPinnedToBottom)
    }

    /// The requirement that makes the view usable while a channel is busy.
    @Test("scrolling up unpins, and new lines do not drag the view back down")
    func scrollingUpHoldsPosition() {
        let harness = makeHarness(viewportHeight: 100)
        harness.controller.append(lines(200))
        harness.controller.flush()
        #expect(harness.controller.isPinnedToBottom)

        harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        harness.controller.scrollPositionChanged()
        #expect(!harness.controller.isPinnedToBottom)

        let originBefore = harness.scrollView.contentView.bounds.origin.y
        harness.controller.append(lines(50, prefix: "new"))
        harness.controller.flush()

        #expect(!harness.controller.isPinnedToBottom)
        #expect(harness.scrollView.contentView.bounds.origin.y == originBefore)
    }

    @Test("lines arriving while scrolled up are counted for the jump affordance")
    func countsUnseenLines() {
        let harness = makeHarness(viewportHeight: 100)
        harness.controller.append(lines(200))
        harness.controller.flush()

        harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        harness.controller.scrollPositionChanged()

        harness.controller.append(lines(7, prefix: "new"))
        harness.controller.flush()
        #expect(harness.controller.unseenLineCount == 7)

        harness.controller.scrollToLatest()
        #expect(harness.controller.isPinnedToBottom)
        #expect(harness.controller.unseenLineCount == 0)
    }

    /// Trimming deletes from the top, which shifts everything below it. Doing that while
    /// someone is reading history yanks the text out from under them, so it waits.
    @Test("trimming is deferred while the user is scrolled up")
    func doesNotTrimWhileScrolledUp() {
        let harness = makeHarness(lineCap: 100, viewportHeight: 100)
        harness.controller.append(lines(150))
        harness.controller.flush()
        #expect(harness.controller.lineCount == 100)

        harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        harness.controller.scrollPositionChanged()

        harness.controller.append(lines(200, prefix: "new"))
        harness.controller.flush()
        #expect(harness.controller.lineCount == 300)  // Held, not trimmed.

        // And caught up as soon as the user returns to the bottom.
        harness.controller.scrollToLatest()
        harness.controller.append(lines(1, prefix: "latest"))
        harness.controller.flush()
        #expect(harness.controller.lineCount == 100)
    }

    /// Deferring the trim cannot become an unbounded buffer for someone who scrolls up
    /// and walks away.
    @Test("a scrolled-up buffer still has a ceiling")
    func unpinnedCeiling() {
        let harness = makeHarness(lineCap: 100, viewportHeight: 100)
        harness.controller.append(lines(50))
        harness.controller.flush()
        harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        harness.controller.scrollPositionChanged()

        harness.controller.append(lines(5000, prefix: "flood"))
        harness.controller.flush()

        let ceiling = 100 * harness.controller.unpinnedCapMultiplier
        #expect(harness.controller.lineCount <= ceiling + ceiling / 10)
    }

    /// Text storage edits are what a flush is measured in.
    private final class EditCounter: NSObject, NSTextStorageDelegate {
        private(set) nonisolated(unsafe) var edits = 0

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            edits += 1
        }
    }
}
