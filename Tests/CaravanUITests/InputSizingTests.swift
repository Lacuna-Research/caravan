import AppKit
import Testing

@testable import CaravanUI

/// How wide the input box thinks it is.
@MainActor
@Suite("Sizing the input box")
struct InputSizingTests {
    private func field(_ text: String, width: CGFloat = 600) -> InputTextView {
        let view = InputTextView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        view.textContainer?.containerSize = NSSize(
            width: width - view.textContainerInset.width * 2,
            height: .greatestFiniteMagnitude
        )
        view.string = text
        return view
    }

    /// **The defect this file exists for.** SwiftUI probes `sizeThatFits` with several
    /// proposals, some very narrow, and the measurement used to leave the last one in the
    /// text container for good — so a box 1676 points wide wrapped after about one word,
    /// with everything past it hidden below a one-line clip. Measuring must not move the
    /// furniture.
    @Test("measuring at a narrow width does not shrink the container")
    func measuringIsFreeOfSideEffects() throws {
        let view = field("the quick brown fox jumps over the lazy dog")
        let before = try #require(view.textContainer?.containerSize.width)

        _ = InputField.size(of: view, fittingWidth: 49, maximumLines: 6)
        #expect(view.textContainer?.containerSize.width == before)

        _ = InputField.size(of: view, fittingWidth: 1, maximumLines: 6)
        _ = InputField.size(of: view, fittingWidth: 10_000, maximumLines: 6)
        #expect(view.textContainer?.containerSize.width == before, "after every probe")
    }

    @Test("a short line is one line high, and a long one is taller")
    func heightFollowsTheText() throws {
        let short = try #require(
            InputField.size(of: field("hi"), fittingWidth: 600, maximumLines: 6)
        )
        let long = try #require(
            InputField.size(
                of: field(String(repeating: "wrap ", count: 60)),
                fittingWidth: 600,
                maximumLines: 6
            )
        )
        #expect(long.height > short.height)
        #expect(short.width == 600)
    }

    /// Six lines and then it scrolls, rather than eating the window.
    @Test("growth stops at the maximum")
    func heightIsClamped() throws {
        let huge = try #require(
            InputField.size(
                of: field(String(repeating: "wrap ", count: 4000)),
                fittingWidth: 600,
                maximumLines: 6
            )
        )
        let six = try #require(
            InputField.size(
                of: field(String(repeating: "wrap ", count: 60)),
                fittingWidth: 600,
                maximumLines: 6
            )
        )
        #expect(huge.height <= six.height * 6, "clamped, not unbounded")
        #expect(huge.height > 0)
    }

    /// The same text needs more rows in a narrower box — the measurement has to actually use
    /// the width it was handed, not the one the view happens to have.
    @Test("a narrower proposal measures taller")
    func widthChangesHeight() throws {
        let text = String(repeating: "wrap ", count: 20)
        let wide = try #require(
            InputField.size(of: field(text), fittingWidth: 900, maximumLines: 6)
        )
        let narrow = try #require(
            InputField.size(of: field(text), fittingWidth: 200, maximumLines: 6)
        )
        #expect(narrow.height > wide.height)
    }

    @Test("a width of nothing is not measured at all")
    func zeroWidth() {
        #expect(InputField.size(of: field("hi"), fittingWidth: 0, maximumLines: 6) == nil)
    }
}
