import Foundation
import IRCProtocol

/// Which window the user is actually looking at.
///
/// Needed the moment a buffer can leave the main window: ⌘W means "close this channel"
/// when the tree is in front of you and "close this window" when a detached buffer is, and
/// a menu item cannot tell the difference without being told.
public enum KeyWindow: Hashable, Sendable {
    case main
    case detached(AppModel.SidebarItem)
}

extension AppModel {
    // MARK: - Detaching

    /// Whether a row has been ejected into a window of its own.
    public func isDetached(_ item: SidebarItem) -> Bool { detachedItems.contains(item) }

    /// Ejects a row into its own window (§1, §10).
    ///
    /// **One affordance for buffers and canvases alike.** §10 is explicit that the canvas's
    /// standalone mode should be "the *same general affordance* used to detach a chat
    /// buffer", not a mechanism special-cased for it — so this takes a `SidebarItem`, which
    /// is already the type that spans both.
    ///
    /// A detached window holds exactly one buffer and has no tree: "detach this", not "open
    /// a second copy of the app". §1 keeps the single window as the primary metaphor.
    public func detach(_ item: SidebarItem) {
        guard !isDetached(item) else {
            windowToFocus = item
            return
        }
        detachedItems.append(item)
        // Leaving the chat area means the same thing as switching away from it: the buffer
        // being left gets its unread rule, and the main window falls back to this network's
        // status window rather than showing a buffer that is now elsewhere.
        if selection == item {
            markUnread(leaving: item)
            // **Never to nothing.** The canvas belongs to no connection, so falling back to
            // "this row's network" left the selection nil — and the live run watched the
            // main window announce "Not connected" while connected to Libera, because an
            // empty selection is also how the app says there is nothing to show.
            selection =
                item.connectionID.map { .status($0) }
                ?? connections.first.map { .status($0.id) }
        }
        windowToFocus = item
    }

    /// Brings a row back into the main window.
    ///
    /// Called both by the Reattach command and by the window simply being closed — closing
    /// a detached window *is* reattaching, because a buffer that existed in neither place
    /// would be a buffer you could no longer reach.
    public func reattach(_ item: SidebarItem, selecting: Bool = true) {
        guard detachedItems.contains(item) else { return }
        detachedItems.removeAll { $0 == item }
        windowToClose = item
        if selecting { reveal(item) }
    }

    /// Detaches whatever the main window is showing. The menu item's action.
    public func detachSelected() {
        guard let selection, !isDetached(selection) else { return }
        detach(selection)
    }

    /// Every buffer currently on screen somewhere: the main window's selection, plus each
    /// detached one.
    ///
    /// **This is what "you have seen it" now means.** Prompt 6 cleared the activity state of
    /// the selected buffer only; a detached buffer is equally in front of you, and a window
    /// showing a conversation that kept flashing for attention would be absurd.
    ///
    /// Deliberately *not* conditioned on which window is key. The main window's selection
    /// has never been — a buffer you are looking at stays clear while the app is in the
    /// background — and one rule that is sometimes generous beats two rules that disagree.
    var onScreenBuffers: [any ChatBuffer] {
        ([selection] + detachedItems).compactMap { $0.flatMap(buffer(for:)) }
    }
}

/// A `SidebarItem` as a string, for `WindowGroup(for:)`.
///
/// SwiftUI identifies the windows of a `WindowGroup` by a `Codable & Hashable` value, and
/// `SidebarItem` holds `IRCChannelName` and `IRCNick` — types in the pure protocol module,
/// which has no business gaining `Codable` for a window-restoration reason. So the
/// conformance is written here, over a flat string, and the pure module stays pure.
///
/// The encoding is deliberately the same shape `BufferBinding` uses — `uuid/#swift` — for
/// no reason beyond there being no reason to invent a second one.
extension AppModel.SidebarItem: Codable {
    private enum Kind: String {
        case status = "s"
        case channel = "c"
        case query = "q"
        case canvas = "x"
        case dashboard = "d"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard let kind = parts.first.flatMap({ Kind(rawValue: String($0)) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "not a sidebar item: \(raw)")
            )
        }
        switch kind {
        case .canvas:
            self = .settingsAndDebug
        case .dashboard:
            self = .dashboard
        case .status:
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "bad status row: \(raw)")
                )
            }
            self = .status(id)
        case .channel, .query:
            guard parts.count == 4, let id = UUID(uuidString: String(parts[1])),
                let mapping = IRCCaseMapping(rawValue: String(parts[2]))
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "bad buffer row: \(raw)")
                )
            }
            let name = String(parts[3])
            self =
                kind == .channel
                ? .channel(connection: id, channel: IRCChannelName(name, mapping: mapping))
                : .query(connection: id, nick: IRCNick(name, mapping: mapping))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawWindowValue)
    }

    /// The flat form. A unit separator joins the fields, because a channel name may contain
    /// almost anything a friendlier delimiter could be.
    var rawWindowValue: String {
        let separator = "\u{1F}"
        switch self {
        case .settingsAndDebug:
            return Kind.canvas.rawValue
        case .dashboard:
            return Kind.dashboard.rawValue
        case .status(let id):
            return [Kind.status.rawValue, id.uuidString].joined(separator: separator)
        case .channel(let id, let channel):
            return [
                Kind.channel.rawValue, id.uuidString, channel.mapping.rawValue, channel.raw,
            ].joined(separator: separator)
        case .query(let id, let nick):
            return [
                Kind.query.rawValue, id.uuidString, nick.mapping.rawValue, nick.raw,
            ].joined(separator: separator)
        }
    }
}
