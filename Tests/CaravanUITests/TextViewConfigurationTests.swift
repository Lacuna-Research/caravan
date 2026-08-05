import AppKit
import Testing

@testable import CaravanUI

/// Guards the configuration the benchmark's conclusion rests on.
///
/// Without these, flipping the engine or making the view editable is a one-word change
/// that nothing objects to until someone notices the app eating 600 MB.
@MainActor
@Suite("Text view configuration")
struct TextViewConfigurationTests {
    @Test("the shipping scrollback uses TextKit 1")
    func shippingViewUsesTextKit1() {
        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        // Asked before anything touches `layoutManager`, which itself forces the
        // downgrade and would make this pass for the wrong reason.
        #expect(textView.textLayoutManager == nil)
        #expect(textView.textStorage != nil)
    }

    @Test("asking for TextKit 2 really gets TextKit 2")
    func textKit2IsReachable() {
        let textView = MessageLogView.makeTextView(usesTextKit2: true)
        #expect(textView.textLayoutManager != nil)
    }

    /// Reading `layoutManager` is the access that silently drops a TextKit 2 view back to
    /// TextKit 1 — worth pinning down, since it is how the first version of the benchmark
    /// managed to measure the wrong engine and believe otherwise.
    @Test("reading layoutManager downgrades a TextKit 2 view")
    func layoutManagerForcesFallback() {
        let textView = MessageLogView.makeTextView(usesTextKit2: true)
        #expect(textView.textLayoutManager != nil)
        _ = textView.layoutManager
        #expect(textView.textLayoutManager == nil)
    }

    @Test("the scrollback is for reading, not editing")
    func readOnly() {
        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(!textView.isRichText)
        #expect(textView.displaysLinkToolTips)
    }
}
