import AppKit

/// The scrollback's text view, which knows what is under a right-click.
///
/// **The hit test is already in the text storage.** `LineRenderer` leaves a ``NickColumn``
/// attribute on every nick column and a `.link` on every URL it detected, so asking "what
/// is under the pointer" is one attribute lookup rather than a second parse of text that
/// has already been parsed twice.
/// **`NSTextView` implements `NSTextFinderClient` and has since 10.7, but does not say so
/// in a header** — which is exactly what `usesFindBar` relies on. Declaring it is what lets
/// this view own its finder instead, and owning it is what makes
/// `noteClientStringWillChange()` reachable when the scrollback is trimmed under an open
/// search. Everything the protocol requires is `NSTextView`'s own.
///
/// The conformance is `@MainActor` because the view is: `NSTextFinderClient` is not isolated
/// in the SDK, and AppKit only ever calls it on the main thread.
extension ScrollbackTextView: @MainActor NSTextFinderClient {}

@MainActor
final class ScrollbackTextView: NSTextView {
    /// Builds the menu for whatever the pointer is over. Set by the buffer's view, which is
    /// the only thing that knows which connection and which channel this scrollback is.
    var contextMenu: ((BufferTarget) -> NSMenu?)?

    // MARK: - Finding

    /// **Our own `NSTextFinder` rather than `usesFindBar`.** The bar and the behaviour are
    /// identical either way; the difference is that this one can be *told* things. The
    /// scrollback is appended to and trimmed from underneath an open search, and the
    /// documented way to keep a finder honest across that is
    /// `noteClientStringWillChange()` — which needs the finder, and `NSTextView` does not
    /// hand out the one it builds for `usesFindBar`.
    private lazy var finder: NSTextFinder = {
        let finder = NSTextFinder()
        finder.client = self
        // Read at first use rather than at construction: the view is put into its scroll
        // view after it is made, and a container captured too early is no container.
        finder.findBarContainer = enclosingScrollView
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
        return finder
    }()

    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
            let action = NSTextFinder.Action(rawValue: tag)
        else { return }
        if finder.findBarContainer == nil { finder.findBarContainer = enclosingScrollView }
        finder.performAction(action)
    }

    /// The scrollback is about to change under an open search.
    func noteTextWillChange() {
        finder.noteClientStringWillChange()
    }

    // MARK: - Copying

    /// ⌘C puts **plain text** on the pasteboard, and only plain text.
    ///
    /// **A deliberate departure from the platform default**, which writes RTF and plain
    /// together and lets the destination choose. The palette is built for a dark window, so
    /// rich text carried out of one lands as pale grey on white in most documents and half
    /// of it is unreadable. Plain is what somebody pasting into a bug report, a terminal or
    /// a message wants nearly every time, and it is the one that cannot arrive invisible.
    /// ``copyWithFormatting(_:)`` is there for the other times, and says so in its name.
    override func copy(_ sender: Any?) {
        writeSelection(to: .general, plainOnly: true)
    }

    /// ⇧⌘C: the styled version, colours and all, as well as the plain fallback.
    @objc func copyWithFormatting(_ sender: Any?) {
        writeSelection(to: .general, plainOnly: false)
    }

    /// Puts the selection on a pasteboard, with or without its styling.
    ///
    /// Takes the board so a test can use one of its own: the general pasteboard belongs to
    /// whoever is at the machine, and a suite that clears it takes their clipboard away.
    func writeSelection(to pasteboard: NSPasteboard, plainOnly: Bool) {
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        pasteboard.clearContents()
        if plainOnly {
            // The selection's own characters, not a re-render: it may be half a line, and
            // what the buffer is showing is what somebody dragged over.
            pasteboard.setString((string as NSString).substring(with: selection), forType: .string)
        } else {
            // **Built here rather than by `writeSelection(to:types:)`.** That asks the view
            // for its writable types, and this view is deliberately `isRichText = false` —
            // which is what stops styled text being *pasted in* — so it offers no RTF to
            // write. The styling is in the storage either way.
            let selected = attributedString().attributedSubstring(from: selection)
            let whole = NSRange(location: 0, length: selected.length)
            pasteboard.declareTypes([.rtf, .string], owner: nil)
            if let rtf = selected.rtf(from: whole, documentAttributes: [:]) {
                pasteboard.setData(rtf, forType: .rtf)
            }
            pasteboard.setString(selected.string, forType: .string)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyWithFormatting(_:)) { return selectedRange().length > 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: point)

        // **A right-click on or beside a selection keeps AppKit's own menu.** Copy, Look Up
        // and Services are what a selection means on macOS, and replacing them with "Whois"
        // for whatever word happens to be under the pointer would be this client overriding
        // a system convention in the one view where selecting text is the point.
        if let index, isSelected(index) { return super.menu(for: event) }
        if index == nil, selectedRange().length > 0 { return super.menu(for: event) }

        let target = index.map { Self.target(in: textStorage, at: $0) } ?? .buffer
        return contextMenu?(target) ?? super.menu(for: event)
    }

    private func isSelected(_ index: Int) -> Bool {
        selectedRanges.contains { NSLocationInRange(index, $0.rangeValue) }
    }

    /// What the storage says is at a character index.
    ///
    /// A link outranks a nick, which cannot actually collide today — a URL inside a nick
    /// column would be a nick containing `://` — but the order has to be *some* order, and
    /// "the more specific thing wins" is the one that stays right if it ever can.
    ///
    /// Static and taking the storage so a test can ask it what is under a character
    /// without laying out a window: the geometry half below needs a real text container,
    /// and the attribute half is the half that carries the meaning.
    static func target(in storage: NSTextStorage?, at index: Int) -> BufferTarget {
        guard let storage, index >= 0, index < storage.length else { return .buffer }
        if let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
            return .link(url)
        }
        // Read back as a `String`: a Swift-only attribute is silently dropped on the way
        // into the storage, so it travels as an `NSString` — see ``NickColumnAttribute``.
        if let encoded = storage.attribute(.nickColumn, at: index, effectiveRange: nil) as? String,
            let column = NickColumn(encoded: encoded)
        {
            return .nick(column.nick)
        }
        return .buffer
    }

    /// The character under a point, or `nil` when the point is past the end of a line.
    ///
    /// **TextKit 1 only**, which is what the app ships (see ``MessageLogView``); under
    /// TextKit 2 there is no layout manager and this answers `nil`, which degrades to the
    /// buffer's own menu rather than to a crash.
    ///
    /// The bounding-rect check is what makes clicking in the empty space to the right of a
    /// short line mean "the buffer" rather than "the last character of that line" —
    /// `glyphIndex(for:in:)` clamps to the nearest glyph and never fails.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: inContainer,
            in: container,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard layoutManager.numberOfGlyphs > glyph else { return nil }
        let bounds = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: container
        )
        guard bounds.contains(inContainer) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
}

extension NSMenu {
    /// An `NSMenu` from a ``BufferMenu`` table, with a group boundary drawn as a separator.
    ///
    /// Returns `nil` for an empty table, because `menu(for:)` returning an empty menu shows
    /// an empty grey rectangle rather than nothing at all.
    @MainActor
    static func buffer(
        _ groups: [[BufferMenuItem]],
        perform: @escaping @MainActor (BufferAction) -> Void
    ) -> NSMenu? {
        let groups = groups.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                let handler = MenuActionHandler(action: item.action, perform: perform)
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(MenuActionHandler.run),
                    keyEquivalent: ""
                )
                menuItem.target = handler
                // `NSMenuItem.target` is weak. The handler has no other owner, so without
                // this the item's action is deallocated before anyone can choose it.
                menuItem.representedObject = handler
                menuItem.isEnabled = item.isEnabled
                menu.addItem(menuItem)
            }
        }
        // Otherwise AppKit asks the responder chain whether each selector is valid, and
        // greys out every item whose target is not a responder — which is all of them.
        menu.autoenablesItems = false
        return menu
    }
}

/// Carries one closure to one menu item. `NSMenuItem` speaks target/action and nothing else.
@MainActor
private final class MenuActionHandler: NSObject {
    private let action: BufferAction
    private let perform: @MainActor (BufferAction) -> Void

    init(action: BufferAction, perform: @escaping @MainActor (BufferAction) -> Void) {
        self.action = action
        self.perform = perform
    }

    @objc func run() {
        perform(action)
    }
}
