import AppKit
import SwiftUI

/// The scrollback: an `NSTextView` in an `NSScrollView`, driven by a
/// ``MessageLogController``.
///
/// A `SwiftUI` `List` or `ScrollView` was never a candidate. Selection across lines,
/// bounded memory, incremental append and honest scroll-position control are all things
/// `NSTextView` does and `List` does not, and the scrollback is the one view that has to
/// stay fast when everything else in the app is idle.
///
/// The view is deliberately dumb: it builds the views and hands them to the controller,
/// which owns the contents from then on. SwiftUI never diffs the text.
public struct MessageLogView: NSViewRepresentable {
    private let controller: MessageLogController

    /// Layout engine.
    ///
    /// **TextKit 1, deliberately.** The prompt said to start with TextKit 2 and fall back
    /// only on evidence; the 50,000-line benchmark is that evidence, and it is not close.
    /// TextKit 2 held 589 MB against TextKit 1's 25 MB for the same text, and its worst
    /// viewport took 85 ms — five dropped frames — where TextKit 1's took 0.01 ms.
    /// Append throughput was a wash (50k versus 54k lines/second). Full numbers, and the
    /// third variant that appends through `NSTextContentStorage`, are in the build log.
    ///
    /// Kept as a parameter so the benchmark can still measure both, and so revisiting
    /// this on a later macOS is a one-line change rather than an excavation.
    private let usesTextKit2: Bool

    public init(controller: MessageLogController, usesTextKit2: Bool = false) {
        self.controller = controller
        self.usesTextKit2 = usesTextKit2
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = MessageLogView.makeTextView(usesTextKit2: usesTextKit2)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        controller.attach(textView: textView, scrollView: scrollView)
        context.coordinator.observeScrolling(of: scrollView)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Nothing: the controller writes to the text storage directly. Anything done
        // here would be a second writer and a source of flicker.
    }

    /// Bridges the clip view's bounds notifications to the controller.
    ///
    /// An `NSObject` so the selector-based registration can be used, which
    /// `NotificationCenter` holds weakly and cleans up on its own.
    @MainActor
    public final class Coordinator: NSObject {
        private let controller: MessageLogController

        init(controller: MessageLogController) {
            self.controller = controller
        }

        // No `deinit` unregistering: `NotificationCenter` holds selector-based observers
        // weakly and stops delivering once they are gone. Removing it by hand would mean
        // touching `self` from a nonisolated `deinit`, which is exactly the unsafe
        // opt-out this arrangement exists to avoid.

        func observeScrolling(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            // Posted on the main thread by AppKit, which is where the controller lives.
            MainActor.assumeIsolated {
                controller.scrollPositionChanged()
            }
        }
    }

    /// Builds the text view, configured for reading rather than editing.
    ///
    /// Shared with the benchmark so the thing measured is the thing shipped.
    @MainActor
    static func makeTextView(usesTextKit2: Bool) -> NSTextView {
        // The one initializer that selects the layout engine *and* leaves the view
        // owning its text system. `NSTextView(frame:)` quietly gives TextKit 1, and
        // `NSTextView(frame:textContainer:)` with a hand-built network requires the
        // caller to keep the storage alive — get that wrong and the view silently ends
        // up with no text system at all.
        let textView = NSTextView(usingTextLayoutManager: usesTextKit2)
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.displaysLinkToolTips = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = LineRenderer.font
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return textView
    }

}
