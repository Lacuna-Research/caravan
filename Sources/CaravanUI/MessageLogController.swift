import AppKit
import Diagnostics
import Observation

/// The engine behind the scrollback: batched appends, bounded memory, and scroll-lock.
///
/// Separate from the `NSViewRepresentable` so it can be driven, and benchmarked, without
/// SwiftUI. It owns the text view's contents; nothing else writes to the text storage.
///
/// Three properties make this the load-bearing component rather than a text field:
///
/// - **One mutation per flush.** Appends are queued and applied as a single
///   `beginEditing`/`endEditing` batch. A 300-line MOTD burst is one layout pass, not
///   300 — the difference between a smooth connect and a visible stall.
/// - **Scroll-lock.** Auto-scroll happens only when the view is already at the bottom.
///   Reading history while a channel is busy is a basic requirement, and a view that
///   yanks itself back down is unusable.
/// - **A line cap.** A client left open for a week must not grow without bound.
@MainActor
@Observable
public final class MessageLogController {
    /// Lines retained before the oldest are dropped.
    public var lineCap: Int

    /// How long appends are gathered before one batched mutation.
    ///
    /// Short enough to feel immediate, long enough that a burst arriving line by line
    /// still collapses into a handful of mutations.
    public var coalesceInterval: Duration

    /// Whether the view is scrolled to the bottom, and therefore whether new lines
    /// should follow.
    public private(set) var isPinnedToBottom = true

    /// Lines that arrived while scrolled up. Drives the "jump to latest" affordance.
    public private(set) var unseenLineCount = 0

    /// Lines currently in the view. Excludes anything still queued.
    public private(set) var lineCount = 0

    /// How far past ``lineCap`` the buffer may grow while the user is scrolled up.
    ///
    /// Trimming deletes from the top, which shifts everything below it — invisible when
    /// pinned to the bottom, and a jarring jump when reading history. So trimming waits
    /// until the user returns to the bottom, and this ceiling stops someone who scrolls
    /// up and walks away from growing the buffer without limit.
    @ObservationIgnored public var unpinnedCapMultiplier = 4

    /// Distance from the bottom, in points, still counted as pinned. A line's height is
    /// more than this, so "one line off the bottom" reads as scrolled up.
    @ObservationIgnored private let pinTolerance: CGFloat = 4

    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private weak var scrollView: NSScrollView?

    /// The view built by ``displayView(usesTextKit2:)``, held strongly so it outlives the
    /// SwiftUI representable that draws it. `nil` when a caller attached its own.
    @ObservationIgnored private var ownedScrollView: NSScrollView?
    @ObservationIgnored private var pending: [AttributedString] = []

    /// Character count of each line in the view, oldest first, including its newline.
    /// Trimming needs to know how much to delete without rescanning the text.
    @ObservationIgnored private var lineLengths: [Int] = []

    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var isScrollingProgrammatically = false

    public init(lineCap: Int = 5000, coalesceInterval: Duration = .milliseconds(50)) {
        self.lineCap = lineCap
        self.coalesceInterval = coalesceInterval
    }

    // MARK: - Appending

    /// Queues lines for the next flush.
    ///
    /// Returns immediately: the text storage is not touched until the coalescing window
    /// closes, so a caller in an event loop never pays for layout.
    public func append(_ lines: [AttributedString]) {
        guard !lines.isEmpty else { return }
        pending.append(contentsOf: lines)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [coalesceInterval] in
            try? await Task.sleep(for: coalesceInterval)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    /// Applies everything queued, now. Called by the timer, and directly by tests and
    /// benchmarks that would rather not wait.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty, let textView, let textStorage = textView.textStorage else {
            // A buffer that has never been on screen has nowhere to write yet, so its
            // lines wait for ``displayView(usesTextKit2:)``. Bounded by the same cap all
            // the same: a busy channel you joined and never clicked on would otherwise
            // grow without limit, which is the one thing this type exists to prevent.
            if pending.count > lineCap { pending.removeFirst(pending.count - lineCap) }
            return
        }

        let signpost = Signposts.scrollback.beginInterval("flush")
        defer { Signposts.scrollback.endInterval("flush", signpost) }

        let wasPinned = isPinnedToBottom
        let batch = NSMutableAttributedString()
        var appendedLengths: [Int] = []
        appendedLengths.reserveCapacity(pending.count)
        for line in pending {
            let attributed = NSAttributedString(line)
            batch.append(attributed)
            batch.append(Self.newline)
            appendedLengths.append(attributed.length + 1)
        }
        pending.removeAll(keepingCapacity: true)
        applyDefaultFont(to: batch)

        // One editing transaction for the append *and* the trim, so layout and the
        // typesetter run once however many lines arrived.
        textStorage.beginEditing()
        textStorage.append(batch)
        lineLengths.append(contentsOf: appendedLengths)
        lineCount = lineLengths.count
        trimIfNeeded(in: textStorage, isPinned: wasPinned)
        textStorage.endEditing()

        if wasPinned {
            scrollToBottom()
        } else {
            unseenLineCount += appendedLengths.count
        }
    }

    /// Fills in the monospaced default wherever a run has no font of its own.
    ///
    /// `AttributedString` cannot carry an `NSFont` under Swift 6 — the type is not
    /// `Sendable` — so the font is applied here, on the AppKit side. Only the gaps are
    /// filled, so a run that *does* specify a font keeps it: prompt 10 will want bold and
    /// italic runs, and blanket-setting the font over the batch would silently undo them.
    private func applyDefaultFont(to batch: NSMutableAttributedString) {
        let font = LineRenderer.font
        let whole = NSRange(location: 0, length: batch.length)
        batch.enumerateAttribute(.font, in: whole) { existing, range, _ in
            guard existing == nil else { return }
            batch.addAttribute(.font, value: font, range: range)
        }
    }

    /// Drops the oldest lines once the buffer is over its cap.
    ///
    /// Trims in one deletion rather than per line, and only once past a slack margin, so
    /// a steady stream does not delete on every single flush.
    private func trimIfNeeded(in textStorage: NSTextStorage, isPinned: Bool) {
        let cap = isPinned ? lineCap : lineCap * max(1, unpinnedCapMultiplier)
        let slack = max(1, cap / 10)
        guard lineLengths.count > cap + slack else { return }

        let excess = lineLengths.count - cap
        let charactersToRemove = lineLengths.prefix(excess).reduce(0, +)
        textStorage.deleteCharacters(in: NSRange(location: 0, length: charactersToRemove))
        lineLengths.removeFirst(excess)
        lineCount = lineLengths.count
    }

    /// Empties the view.
    public func clear() {
        pending.removeAll()
        flushTask?.cancel()
        flushTask = nil
        lineLengths.removeAll()
        lineCount = 0
        unseenLineCount = 0
        textView?.textStorage?.setAttributedString(NSAttributedString())
    }

    // MARK: - Scrolling

    /// Scrolls to the newest line and resumes following.
    public func scrollToLatest() {
        isPinnedToBottom = true
        unseenLineCount = 0
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let textView else { return }
        isScrollingProgrammatically = true
        defer { isScrollingProgrammatically = false }
        // `scrollToEndOfDocument` rather than arithmetic on the frame height: under
        // TextKit 2 the document's height is an estimate until the text is laid out, so
        // computing the offset ourselves scrolls to the wrong place. AppKit knows how to
        // ask for the layout it needs.
        textView.scrollToEndOfDocument(nil)
    }

    /// Recomputes ``isPinnedToBottom`` from where the view actually is.
    ///
    /// Called by the representable's coordinator when the clip view's bounds change, and
    /// directly by tests, which have no notification to wait for.
    public func scrollPositionChanged() {
        guard !isScrollingProgrammatically, let textView, let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let distanceFromBottom = textView.frame.height - visible.maxY
        let pinned = distanceFromBottom <= pinTolerance
        if pinned != isPinnedToBottom {
            isPinnedToBottom = pinned
            if pinned { unseenLineCount = 0 }
        }
    }

    // MARK: - Attachment

    /// Adopts a text view. The controller writes to its storage from here on.
    ///
    /// Watching for scroll changes is the caller's job — the representable's coordinator
    /// does it, and a test drives ``scrollPositionChanged()`` itself. Registering here
    /// would mean unregistering in `deinit`, which a `@MainActor` type cannot do without
    /// an unsafe opt-out.
    public func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    /// The scroll view this buffer is drawn in, built once and reused for the life of the
    /// controller.
    ///
    /// **The controller owns the view, not the other way round.** SwiftUI tears a
    /// representable's `NSView` down whenever it stops being on screen, and the text a
    /// buffer holds lives *in* that view's storage — so a freshly built one per
    /// appearance means every buffer goes blank the moment you look at another one. That
    /// is not a hypothetical: it is what the first live run of the channel window did.
    ///
    /// Reusing it keeps the scroll position too, which is the behaviour anyone who has
    /// used an IRC client expects on switching back to a window.
    public func displayView(usesTextKit2: Bool = false) -> NSScrollView {
        if let ownedScrollView { return ownedScrollView }

        let scrollView = NSScrollView()
        let textView = MessageLogView.makeTextView(usesTextKit2: usesTextKit2)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        ownedScrollView = scrollView
        attach(textView: textView, scrollView: scrollView)
        // Lines that arrived before there was anywhere to put them. A channel joined in
        // the background has its whole history queued up at this point.
        flush()
        return scrollView
    }

    private static let newline = NSAttributedString(string: "\n")
}
