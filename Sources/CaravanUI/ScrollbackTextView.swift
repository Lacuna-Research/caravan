import AppKit

/// The scrollback's text view, which knows what is under a right-click.
///
/// **The hit test is already in the text storage.** `LineRenderer` leaves a ``NickColumn``
/// attribute on every nick column and a `.link` on every URL it detected, so asking "what
/// is under the pointer" is one attribute lookup rather than a second parse of text that
/// has already been parsed twice.
@MainActor
final class ScrollbackTextView: NSTextView {
    /// Builds the menu for whatever the pointer is over. Set by the buffer's view, which is
    /// the only thing that knows which connection and which channel this scrollback is.
    var contextMenu: ((BufferTarget) -> NSMenu?)?

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
