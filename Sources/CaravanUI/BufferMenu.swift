import Foundation
import IRCProtocol

/// What the pointer is over, once the hit test has run.
///
/// One type for both halves of this prompt. A nick in the nick list, a nick in a `<bob>`
/// column and a URL in a MOTD are three different things to *find* and one thing to
/// *answer*, and keeping the answer in one place is what stops the nick list's menu and
/// the scrollback's menu drifting apart.
public enum BufferTarget: Hashable, Sendable {
    case nick(String)
    case link(URL)
    /// Not over anything in particular — the buffer itself.
    case buffer
}

/// What choosing a context-menu item does.
///
/// **`command` is the interesting case, and it is deliberately a string.** Every action on
/// a person goes back through the same command path a typed line takes, rather than
/// reaching into `ConnectionViewModel` for a bespoke call. Two things follow: the menu
/// cannot drift from the command — `/op` fixed once is fixed in both — and stage 3's
/// script-driven menus become a change to this table rather than a rewrite of the plumbing.
public enum BufferAction: Hashable, Sendable {
    /// A command line, `/whois bob`, run against the buffer the menu was opened from.
    case command(String)
    case open(URL)
    case copy(String)
    case showURLCatcher
    case showChannelModes
}

/// One item of a context menu.
public struct BufferMenuItem: Identifiable, Hashable, Sendable {
    public let title: String
    public let action: BufferAction

    /// **Disabled rather than absent** where we hold no operator prefix. A menu whose
    /// items come and go teaches nobody what the client can do; one that greys them out
    /// says both what exists and why you cannot have it right now.
    public let isEnabled: Bool

    public var id: String { title }

    public init(_ title: String, _ action: BufferAction, isEnabled: Bool = true) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// The menus themselves: what you can do to the thing under the pointer.
///
/// Pure, and returning groups rather than a flat list — a group boundary is a separator,
/// which keeps the divider logic out of both the SwiftUI and the AppKit renderer. Tested
/// as data, so the table can be checked without putting a window on screen.
public enum BufferMenu {
    /// mIRC's, word for word, and it has been that trout since 1995.
    static func slap(_ nick: String) -> String {
        "/me slaps \(nick) around a bit with a large trout"
    }

    /// The menu for a target, in the context of a buffer.
    ///
    /// - Parameters:
    ///   - channel: the channel this menu was opened in, or `nil` in a query or a status
    ///     window — which is what decides whether the membership items exist at all.
    ///   - canSetModes: whether we hold a prefix here. See ``ChannelBuffer/canSetModes(as:)``.
    public static func items(
        for target: BufferTarget,
        channel: IRCChannelName? = nil,
        canSetModes: Bool = false
    ) -> [[BufferMenuItem]] {
        switch target {
        case .nick(let nick): nickItems(nick, channel: channel, canSetModes: canSetModes)
        case .link(let url): linkItems(url)
        case .buffer: bufferItems(channel: channel)
        }
    }

    private static func nickItems(
        _ nick: String,
        channel: IRCChannelName?,
        canSetModes: Bool
    ) -> [[BufferMenuItem]] {
        var groups: [[BufferMenuItem]] = [
            [
                BufferMenuItem("Whois", .command("/whois \(nick)")),
                BufferMenuItem("Query", .command("/query \(nick)")),
            ]
        ]

        // **Only in a channel.** `/op` in a conversation has no channel to name, and an
        // item that could only ever produce "no target in this window" is not an item.
        if channel != nil {
            groups.append([
                BufferMenuItem("Op", .command("/op \(nick)"), isEnabled: canSetModes),
                BufferMenuItem("Deop", .command("/deop \(nick)"), isEnabled: canSetModes),
                BufferMenuItem("Voice", .command("/voice \(nick)"), isEnabled: canSetModes),
                BufferMenuItem("Devoice", .command("/devoice \(nick)"), isEnabled: canSetModes),
            ])
            // Both signs of each, always, rather than one item that guesses which you
            // meant: `PREFIX` says which prefixes exist and not which of them outrank
            // which, so a client that hid "Deop" would sometimes hide the one you wanted.
            groups.append([
                BufferMenuItem("Kick", .command("/kick \(nick)"), isEnabled: canSetModes),
                BufferMenuItem("Ban", .command("/ban \(nick)"), isEnabled: canSetModes),
                BufferMenuItem(
                    "Kick and Ban",
                    .command("/kickban \(nick)"),
                    isEnabled: canSetModes
                ),
            ])
        }

        groups.append([BufferMenuItem("Slap", .command(slap(nick)))])
        return groups
    }

    private static func linkItems(_ url: URL) -> [[BufferMenuItem]] {
        [
            [
                BufferMenuItem("Open Link", .open(url)),
                BufferMenuItem("Copy Link", .copy(url.absoluteString)),
            ],
            [BufferMenuItem("URL Catcher\u{2026}", .showURLCatcher)],
        ]
    }

    private static func bufferItems(channel: IRCChannelName?) -> [[BufferMenuItem]] {
        var groups: [[BufferMenuItem]] = []
        if channel != nil {
            groups.append([BufferMenuItem("Channel Modes\u{2026}", .showChannelModes)])
        }
        groups.append([BufferMenuItem("URL Catcher\u{2026}", .showURLCatcher)])
        return groups
    }
}
