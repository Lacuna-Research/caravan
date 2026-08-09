import AppKit

/// The menu-bar item: how many buffers want you, and which.
///
/// **Off by default.** It is the one surface in this prompt that takes space the user did
/// not ask for, and the Dock badge already answers "is anybody talking to me". On, it earns
/// the space by answering the next question too — *who* — without bringing the app forward.
///
/// An `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, which is a `Scene` and therefore
/// cannot be created and destroyed from a setting: `MenuBarExtra(isInserted:)` needs a
/// binding into the scene graph, and the scene graph is in the app target where nothing is
/// testable. This is thirty lines and can be driven from a model.
@MainActor
public final class MenuBarItem {
    private var item: NSStatusItem?

    /// What the menu lists, refreshed each time it opens. Set by ``update(count:rows:)``.
    private var rows: [Row] = []

    /// One buffer wanting attention.
    public struct Row: Hashable, Sendable {
        public let title: String
        public let item: AppModel.SidebarItem
        public let isHighlight: Bool

        public init(title: String, item: AppModel.SidebarItem, isHighlight: Bool) {
            self.title = title
            self.item = item
            self.isHighlight = isHighlight
        }
    }

    /// Called when a row is chosen. Set by `AppModel`, which is what can focus a buffer.
    public var onSelect: (@MainActor (AppModel.SidebarItem) -> Void)?

    public init() {}

    public var isShowing: Bool { item != nil }

    /// Puts the item in the menu bar, or takes it out. Idempotent, so a setting can call it
    /// on every change without checking.
    public func setVisible(_ visible: Bool) {
        guard visible != isShowing else { return }
        guard visible else {
            item.map { NSStatusBar.system.removeStatusItem($0) }
            item = nil
            return
        }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        created.button?.image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right",
            accessibilityDescription: "Caravan"
        )
        item = created
        refreshMenu()
    }

    /// The count beside the icon, and what the menu holds.
    ///
    /// **The count is passed in rather than derived here.** `AppModel.allBuffers` is the one
    /// place that knows, and a status item that counted for itself would be a second answer
    /// to the same question — the exact mistake the Dock badge avoids by being recomputed.
    public func update(count: Int, rows: [Row]) {
        self.rows = rows
        guard let button = item?.button else { return }
        button.title = count > 0 ? " \(count)" : ""
        refreshMenu()
    }

    private func refreshMenu() {
        guard let item else { return }
        let menu = NSMenu()
        if rows.isEmpty {
            let empty = NSMenuItem(title: "Nothing waiting", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for row in rows {
                let entry = NSMenuItem(
                    title: row.title,
                    action: #selector(Target.choose(_:)),
                    keyEquivalent: ""
                )
                entry.target = target
                entry.representedObject = row.item
                // The badge state, as a dot rather than a second column of numbers — §3's
                // rule that badges are for highlights only, kept here too.
                if row.isHighlight {
                    entry.image = NSImage(
                        systemSymbolName: "circle.fill",
                        accessibilityDescription: nil
                    )
                }
                menu.addItem(entry)
            }
        }
        item.menu = menu
    }

    /// `NSMenuItem` wants an Objective-C target, which a Swift closure is not.
    private lazy var target = Target { [weak self] item in self?.onSelect?(item) }

    private final class Target: NSObject {
        private let action: @MainActor (AppModel.SidebarItem) -> Void

        init(action: @escaping @MainActor (AppModel.SidebarItem) -> Void) {
            self.action = action
        }

        @MainActor
        @objc func choose(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? AppModel.SidebarItem else { return }
            action(item)
        }
    }
}
