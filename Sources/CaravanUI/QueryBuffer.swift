import Foundation
import IRCFormat
import IRCProtocol
import Observation

/// One private conversation: its scrollback, its input box, and enough of what has been
/// said to fill the header band.
///
/// The third buffer shape beside ``ChannelBuffer`` and the status window, and
/// deliberately *not* a `ChannelBuffer` with an empty member list — a query has no
/// membership, no topic and no modes, and giving it hollow versions of all three would
/// invite code that reads them.
@MainActor
@Observable
public final class QueryBuffer: Identifiable {
    /// Who the conversation is with, folded under the server's casemapping — so a person
    /// who capitalises their nick differently from one line to the next stays one window.
    public let nick: IRCNick

    public let log = MessageLogController()

    /// This window's input box and command history, per buffer like every other.
    public let input = InputState()

    /// What the header band shows (GUI-DESIGN-NOTES.md §14).
    public private(set) var conversation = Conversation()

    public nonisolated var id: IRCNick { nick }

    init(nick: IRCNick) {
        self.nick = nick
    }

    /// Notes a line of the conversation, for the header band.
    ///
    /// Both directions, because "first and last message" is a fact about the
    /// *conversation* — a band that showed only what the other person said would report
    /// the wrong last message every time you had the last word.
    func record(sender: String, text: String, isAction: Bool, at when: Date) {
        conversation.record(
            .init(
                sender: sender,
                // Stripped, not parsed: the band is plain `Text`, and a `^C` reaching it
                // renders as a control picture rather than as colour.
                text: IRCFormatting.stripping(text),
                isAction: isAction,
                at: when
            )
        )
    }

    /// The band's content, or `nil` when nothing has been said yet.
    ///
    /// Three lines at most, which the band shrinks to two with a chevron — the shrink
    /// behaviour `HeaderBand` already has, used here rather than reinvented.
    ///
    /// **Latest before first, which is not the order §14 lists them in.** The live run
    /// showed why: collapsed to two lines, the band was the count and the *opening* line
    /// of the conversation, and the one thing worth seeing at a glance — what was said
    /// most recently — was the line hidden behind the chevron.
    public var contextSummary: String? {
        guard let first = conversation.first, let latest = conversation.latest else {
            return nil
        }
        let count = conversation.messageCount
        guard count > 1 else {
            return "1 message at \(Self.time(first.at))\n\(first.summary)"
        }
        return """
            \(count) messages since \(Self.time(first.at))
            Latest — \(latest.summary)
            First — \(first.summary)
            """
    }

    /// The band's placeholder, for a window opened before anyone has said anything —
    /// which `/query bob` does deliberately.
    public var contextPlaceholder: String {
        "No messages yet in this conversation with \(nick.raw)"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// The conversational context a query's header band shows: how much has been said, and
/// the two ends of it.
///
/// Only the two ends are kept. The middle is the scrollback's job, and a header that
/// accumulated every line would be a second copy of the buffer.
public struct Conversation: Sendable, Equatable {
    /// One end of the conversation.
    public struct Entry: Sendable, Equatable {
        public var sender: String
        public var text: String
        public var isAction: Bool
        public var at: Date

        /// `bob: are you around?`, or `* bob waves` for an action.
        ///
        /// Truncated, because a header band is not a place to read a paragraph and the
        /// band's own two-line shrink would otherwise hide the *latest* message behind
        /// one long first one.
        public var summary: String {
            let body =
                text.count > Self.limit
                ? text.prefix(Self.limit).trimmingCharacters(in: .whitespaces) + "…"
                : text
            return isAction ? "* \(sender) \(body)" : "\(sender): \(body)"
        }

        private static let limit = 120
    }

    public private(set) var messageCount = 0
    public private(set) var first: Entry?
    public private(set) var latest: Entry?

    public init() {}

    mutating func record(_ entry: Entry) {
        messageCount += 1
        if first == nil { first = entry }
        latest = entry
    }
}
