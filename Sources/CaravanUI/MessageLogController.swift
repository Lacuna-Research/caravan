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
    ///
    /// Lowering it takes effect at once rather than at the next line to arrive: a quiet
    /// buffer would otherwise sit above its new cap indefinitely, which reads as the
    /// setting having done nothing.
    public var lineCap: Int {
        didSet { trimNow() }
    }

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

    /// The chat font. One font governs every buffer, so the owner sets this from the
    /// settings and the controller only draws with it.
    ///
    /// Changing it restyles what is already on screen. A font setting that applied only to
    /// lines arriving after you changed it would leave the buffer in two fonts, which is
    /// both ugly and a lie about what the setting does.
    @ObservationIgnored public var chatFont: NSFont {
        didSet {
            guard chatFont != oldValue else { return }
            restyle()
        }
    }

    /// How open the lines are (§15.5). Like the font, changing it restyles what is already
    /// on screen — a density that applied only to arriving lines would leave the buffer in
    /// two densities, which is worse than not offering the setting.
    @ObservationIgnored public var density: ChatSettings.Density = .normal {
        didSet {
            guard density != oldValue else { return }
            restyle()
        }
    }

    /// Which colours this buffer draws mIRC indices and nicks in.
    ///
    /// Changing it reaches text already on screen, by two different routes:
    ///
    /// - **The Auto / Light / Dark mode goes to the view's appearance.** Every indexed
    ///   colour in the storage resolves itself against whichever appearance is drawing it,
    ///   so pinning the scrollback's repaints the whole buffer — background, semantic line
    ///   colours and mIRC colours together — with no pass over the text at all.
    /// - **Nick colouring goes through ``restyle()``**, which rebuilds each nick from the
    ///   ``NickColumn`` the renderer left behind. That one is a real choice about what the
    ///   line says rather than about what the window looks like, so no appearance can
    ///   express it.
    @ObservationIgnored public var palette: Palette {
        didSet {
            guard palette != oldValue else { return }
            // Lines queued under the old palette first, or they arrive already stale and
            // the restyle below has nothing to correct them with.
            flush()
            applyPaletteAppearance()
            restyle()
        }
    }

    /// Which line holds the unread rule, as an index into ``lineLengths``.
    ///
    /// An index rather than a character offset, because trimming from the top moves every
    /// offset below it and an index only has to be decremented.
    @ObservationIgnored private var unreadMarkerLine: Int?

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

    public init(
        lineCap: Int = 5000,
        coalesceInterval: Duration = .milliseconds(50),
        palette: Palette = Palette()
    ) {
        self.lineCap = lineCap
        self.coalesceInterval = coalesceInterval
        self.chatFont = ChatFont.nsFont()
        self.palette = palette
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
            let attributed = Self.converted(line)
            batch.append(attributed)
            batch.append(Self.newline)
            appendedLengths.append(attributed.length + 1)
        }
        pending.removeAll(keepingCapacity: true)
        applyChatAttributes(to: batch)

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

    /// Fills in the chat font and the grid rules wherever a run has no font of its own.
    ///
    /// `AttributedString` cannot carry an `NSFont` under Swift 6 — the type is not
    /// `Sendable` — so this happens here, on the AppKit side. Only the gaps are filled, so
    /// a run that *does* specify a font keeps it: stage 2's formatting codes want bold and
    /// italic runs, and blanket-setting the font over the batch would silently undo them.
    ///
    /// The paragraph style goes on unconditionally. It carries the rules that make a
    /// monospaced grid stay a grid — no head indent, so wrapped lines run flush-left at
    /// column 0 rather than hanging under the message column, and a clamped line height so
    /// pasted Zalgo cannot blow one line to hundreds of points.
    private func applyChatAttributes(to batch: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: batch.length)
        batch.addAttributes(
            [
                .ligature: 0,
                .paragraphStyle: ChatFont.paragraphStyle(for: chatFont, density: density),
            ],
            range: whole
        )
        applyFont(to: batch, in: whole)
    }

    /// Converts a rendered line for the text storage, **naming our own attribute scope**.
    ///
    /// `NSAttributedString(someAttributedString)` carries only the scopes it knows about,
    /// and silently drops everything else — so the plain initializer threw away every
    /// ``InlineTraits`` on the way in, and bold text arrived unbold with nothing to show
    /// for it. Naming the scope is what keeps a custom attribute alive across the bridge.
    private static func converted(_ line: AttributedString) -> NSAttributedString {
        (try? NSAttributedString(line, including: \.caravan)) ?? NSAttributedString(line)
    }

    /// Fills in the chat font, wearing whatever traits each run asked for.
    ///
    /// The renderer cannot do this: an `NSFont` is not `Sendable`, so it cannot go into an
    /// `AttributedString`. It leaves ``InlineTraits`` behind instead, and this is the one
    /// place that knows both the traits and the current chat font — which is what lets a
    /// font change restyle bold text back into bold text.
    private func applyFont(to text: NSMutableAttributedString, in range: NSRange) {
        let font = chatFont
        text.enumerateAttribute(.inlineTraits, in: range) { value, subrange, _ in
            let traits = (value as? NSNumber).map { InlineTraits(rawValue: $0.uint8Value) } ?? []
            text.addAttribute(.font, value: traits.applied(to: font), range: subrange)
        }
    }

    /// Recolours every nick column from the current palette.
    ///
    /// The renderer already coloured them for the palette in force when the line was
    /// built; this is what makes turning nick colouring on or off reach lines already in
    /// the buffer. With it off, the nick goes back to its line's own colour — which is
    /// what the ``NickColumn`` carries the role for, since by then the storage has the
    /// nick's colour where the line's used to be.
    /// Re-resolves every run that named a mIRC colour index.
    ///
    /// **What makes a colour override reach text already on screen.** An indexed colour
    /// goes into the storage as an appearance-resolving `NSColor`, so switching between the
    /// light and dark tables needs no pass at all — but retuning what index 4 *means*
    /// changes the value rather than the appearance, and a resolved colour cannot know.
    /// The live run found this the honest way: resetting a colour left the lines above it
    /// in the old palette.
    ///
    /// Runs with only a `^D` hex colour carry no attribute and are skipped, which is the
    /// behaviour §5 asks for — an override does not apply to a value the sender named
    /// exactly.
    private func applyInlineColours(to text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.inlineColours, in: range) { value, subrange, _ in
            guard let encoded = value as? String,
                let colours = InlineColours(encoded: encoded)
            else { return }
            let (foreground, background) = palette.resolved(colours)
            if let foreground {
                text.addAttribute(.foregroundColor, value: foreground, range: subrange)
            }
            if let background {
                text.addAttribute(.backgroundColor, value: background, range: subrange)
            }
        }
    }

    private func applyNickColours(to text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.nickColumn, in: range) { value, subrange, _ in
            guard let encoded = value as? String,
                let column = NickColumn(encoded: encoded)
            else { return }
            let colour = palette.colour(forNick: column.nick) ?? column.base.nsColor
            text.addAttribute(.foregroundColor, value: colour, range: subrange)
        }
    }

    /// Pins the scrollback to the palette's appearance, or lets it follow the system.
    private func applyPaletteAppearance() {
        scrollView?.appearance = palette.mode.nsAppearance
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
        // The rule is tracked by line index, so a trim shifts it — and a rule old enough
        // to be trimmed away is gone rather than dangling at some other line's position.
        if let index = unreadMarkerLine {
            unreadMarkerLine = index >= excess ? index - excess : nil
        }
    }

    /// Trims to the current cap without waiting for a line to arrive.
    private func trimNow() {
        guard let textStorage = textView?.textStorage else { return }
        textStorage.beginEditing()
        trimIfNeeded(in: textStorage, isPinned: isPinnedToBottom)
        textStorage.endEditing()
    }

    /// Reapplies the chat font and the grid rules to everything already on screen.
    ///
    /// **Rebuilds each run's font from its traits rather than overwriting it.** A blanket
    /// `addAttribute(.font:)` was correct only while every run wore the plain chat font;
    /// with inline formatting on the wire it would flatten every bold and italic run in
    /// the buffer the moment somebody nudged the font size.
    private func restyle() {
        guard let textStorage = textView?.textStorage, textStorage.length > 0 else { return }
        let wasPinned = isPinnedToBottom
        let whole = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.addAttributes(
            [
                .ligature: 0,
                .paragraphStyle: ChatFont.paragraphStyle(for: chatFont, density: density),
            ],
            range: whole
        )
        applyFont(to: textStorage, in: whole)
        // Inline colours before nick colours: a nick column can carry both, and the nick's
        // own colour is the one that has to win there.
        applyInlineColours(to: textStorage, in: whole)
        applyNickColours(to: textStorage, in: whole)
        // The unread rule is deliberately wider than the window and clipped rather than
        // wrapped, so the blanket pass above has to be undone for its one line.
        if let index = unreadMarkerLine, index < lineLengths.count {
            let location = lineLengths.prefix(index).reduce(0, +)
            textStorage.addAttribute(
                .paragraphStyle,
                value: ChatFont.clippingParagraphStyle(for: chatFont, density: density),
                range: NSRange(location: location, length: lineLengths[index])
            )
        }
        textStorage.endEditing()
        if wasPinned { scrollToBottom() }
    }

    // MARK: - The unread marker

    /// Whether a rule is currently drawn. For tests, and for deciding whether to redraw.
    public var hasUnreadMarker: Bool { unreadMarkerLine != nil }

    /// Draws the unread rule at the end of the buffer, moving any existing one.
    ///
    /// Called when a buffer is *left*, which is what makes the rule mean "everything above
    /// this you have seen". It persists while you are away and while you are reading —
    /// not cleared the instant it scrolls into view, which would defeat the point — and
    /// moves only the next time you leave.
    public func markUnreadPosition(with rule: AttributedString) {
        flush()
        guard let textView, let textStorage = textView.textStorage else { return }

        let wasPinned = isPinnedToBottom
        textStorage.beginEditing()
        removeUnreadMarker(from: textStorage)

        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(rule))
        attributed.append(Self.newline)
        let whole = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .font: chatFont,
                .ligature: 0,
                // Clipping, not wrapping: the rule is deliberately longer than any window
                // so it always spans the width, and a wrapped rule would be two rules.
                .paragraphStyle: ChatFont.clippingParagraphStyle(
                    for: chatFont,
                    density: density
                ),
            ],
            range: whole
        )
        textStorage.append(attributed)
        lineLengths.append(attributed.length)
        lineCount = lineLengths.count
        unreadMarkerLine = lineLengths.count - 1
        textStorage.endEditing()

        if wasPinned { scrollToBottom() }
    }

    private func removeUnreadMarker(from textStorage: NSTextStorage) {
        guard let index = unreadMarkerLine, index < lineLengths.count else {
            unreadMarkerLine = nil
            return
        }
        let location = lineLengths.prefix(index).reduce(0, +)
        textStorage.deleteCharacters(in: NSRange(location: location, length: lineLengths[index]))
        lineLengths.remove(at: index)
        lineCount = lineLengths.count
        unreadMarkerLine = nil
    }

    /// Empties the view.
    public func clear() {
        pending.removeAll()
        flushTask?.cancel()
        flushTask = nil
        lineLengths.removeAll()
        lineCount = 0
        unseenLineCount = 0
        unreadMarkerLine = nil
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
        applyPaletteAppearance()
        applyContextMenu()
    }

    /// Builds the right-click menu for whatever the pointer is over.
    ///
    /// Set by the buffer's view, which is the only thing that knows which connection and
    /// which channel this scrollback belongs to — the controller knows neither, and giving
    /// it either would make it the second place that has to be told when a buffer moves
    /// between windows.
    @ObservationIgnored public var contextMenu: ((BufferTarget) -> NSMenu?)? {
        didSet { applyContextMenu() }
    }

    private func applyContextMenu() {
        (textView as? ScrollbackTextView)?.contextMenu = contextMenu
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
