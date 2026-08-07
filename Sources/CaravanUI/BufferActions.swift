import AppKit
import IRCProtocol
import IRCSession
import SwiftUI

/// Everything one buffer's window can do to the thing under the pointer.
///
/// A small value carried by the buffer views and handed to both the nick list and the
/// scrollback, so the two menus are literally the same menu. It holds the three things
/// ``BufferMenu`` cannot know: which connection this window is showing, which buffer, and
/// which window a sheet opened from it should land on.
///
/// **Every field is a reference or a constant**, deliberately: the scrollback's menu is
/// built when the pointer is over something, long after the view that supplied this was
/// laid out, and a `canSetModes` snapshotted at build time would still say "you are not an
/// operator" ten minutes after somebody opped you.
@MainActor
struct BufferActions {
    let model: AppModel

    /// **This window's network, not the tree's selection.** The reason this type exists.
    let connection: ConnectionViewModel

    /// The channel window this belongs to, or `nil` in a conversation or a status window —
    /// which is what decides whether the membership items appear at all.
    let channel: ChannelBuffer?

    /// Where a command typed here would go.
    let target: Target?

    let window: KeyWindow

    var canSetModes: Bool { channel?.canSetModes(as: connection.currentNick) ?? false }

    func items(for hit: BufferTarget) -> [[BufferMenuItem]] {
        BufferMenu.items(for: hit, channel: channel?.name, canSetModes: canSetModes)
    }

    func perform(_ action: BufferAction) {
        Task { await model.perform(action, on: connection, from: target, in: window) }
    }

    /// The AppKit menu for a hit, which is what the scrollback's `NSTextView` needs.
    func menu(for hit: BufferTarget) -> NSMenu? {
        NSMenu.buffer(items(for: hit)) { perform($0) }
    }
}

/// The SwiftUI half of the same menu, for the views that are SwiftUI all the way down.
struct BufferMenuItems: View {
    let target: BufferTarget
    let actions: BufferActions

    var body: some View {
        // A group boundary is a separator. Indexed because the groups are positional and
        // two of them can hold items with equal titles across different buffers.
        let groups = actions.items(for: target)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { item in
                Button(item.title) { actions.perform(item.action) }
                    .disabled(!item.isEnabled)
            }
        }
    }
}

extension AppModel {
    /// Carries out a context-menu choice.
    ///
    /// The first case is the interesting one: a menu item is a command string, and it goes
    /// back through the same path a typed line takes. Nothing here reaches into
    /// `ConnectionViewModel` for a private route, which is what keeps `/op` from having two
    /// implementations and makes stage 3's script-driven menus a change to ``BufferMenu``
    /// rather than to any of this.
    public func perform(
        _ action: BufferAction,
        on connection: ConnectionViewModel?,
        from target: Target?,
        in window: KeyWindow = .main
    ) async {
        switch action {
        case .command(let text):
            await submit(text, from: target, on: connection)
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .copy(let text):
            Self.copyToPasteboard(text)
        case .showURLCatcher:
            urlCatcherPresentation = URLCatcherPresentation(
                window: window,
                network: connection?.displayName,
                buffer: bufferName(of: target, on: connection)
            )
        case .showChannelModes:
            isShowingChannelModes = true
        }
    }

    /// The name the catcher recorded a buffer under — the same string ``ChatBuffer``
    /// shows in the tree, so the scope filter matches what was written when the line
    /// arrived.
    private func bufferName(of target: Target?, on connection: ConnectionViewModel?) -> String? {
        switch target {
        case .channel(let name)?: name.raw
        case .nick(let nick)?: nick.raw
        case nil: connection?.status.displayName
        }
    }

    /// Plain text, which is what a URL pasted into an address bar or into an editor
    /// both want.
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
