import AppKit
import IRCSession

/// How much a buffer wants your attention (GUI-DESIGN-NOTES.md §3).
///
/// mIRC's four states, kept because they carry more information per pixel than a badge
/// count does, and information density is a goal here rather than an accident of 1995.
/// **Badges are additive for the highlight case only** — a badge on every state is a
/// wall of numbers, and a wall of numbers is read as decoration.
///
/// `Comparable` because the only arithmetic anything does with these is "the more urgent
/// of the two": a buffer takes the highest state reached since you last looked at it, and
/// a collapsed network group shows the highest among its hidden children.
public enum BufferActivity: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Nothing new. You have seen everything here.
    case none = 0
    /// Something happened — a join, a mode, a numeric. Not somebody talking.
    case activity = 1
    /// Somebody said something.
    case message = 2
    /// Somebody said something *to you*.
    case highlight = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether this state carries a badge. Highlights only, per §3.
    public var showsBadge: Bool { self == .highlight }

    /// The tree row's colour.
    ///
    /// **Escalating, and colour-coded rather than weight-coded alone**, which is what §3
    /// asks for. A buffer with nothing new *recedes* — it is the only state quieter than
    /// an ordinary row — and the three above it climb from the ordinary label colour,
    /// through the teal this app already draws events in, to pink.
    ///
    /// **Not the accent colour**, which was the first attempt and which the live run
    /// killed: this machine's accent is Graphite, so `controlAccentColor` resolves to
    /// grey and the most important of the four states was indistinguishable from an
    /// ordinary row. The unread *rule* can afford to follow the accent because it is a
    /// line across the window, findable by shape; a single word in a tree cannot.
    ///
    /// Pink rather than red, which is reserved for errors, and rather than orange, which
    /// the connection indicator already uses a few pixels away on the same row.
    @MainActor
    public var colour: NSColor {
        switch self {
        case .none: .secondaryLabelColor
        case .activity: .labelColor
        case .message: LineColour.event.nsColor
        case .highlight: LineColour.action.nsColor
        }
    }

    /// Whether the row is drawn bold. The top state only: bold everywhere is bold nowhere.
    public var isBold: Bool { self == .highlight }

    /// What one event does to the buffer it lands in.
    ///
    /// Deliberately a pure function of the event, our own nick and whether the buffer is a
    /// conversation — so the whole table is a table, testable without a tree to look at.
    ///
    /// **A private message is a highlight, not merely a message.** §3 does not say so;
    /// §18 does, by grouping "highlights and private messages" as the two things worth
    /// notifying about. A query buffer that could only ever reach `message` would wear the
    /// same colour as somebody chatting in `#swift`, and the whole reason a PM has its own
    /// window is that it is addressed to you.
    public static func caused(
        by event: IRCEvent,
        ownNick: String,
        isConversation: Bool
    ) -> BufferActivity {
        switch event {
        case .message(_, let sender, let text, _, _, _):
            // Our own words coming back under `echo-message` are not news. Without the
            // capability they never reach this path at all, which is the asymmetry this
            // line exists to close.
            if let nick = sender.nick, nick.lowercased() == ownNick.lowercased() {
                return .none
            }
            if isConversation { return .highlight }
            return mentions(ownNick, in: text) ? .highlight : .message

        case .raw, .channelChanged, .channelClosed, .namesReply, .endOfNames,
            .batchStarted, .batchEnded, .bouncerNetworks, .capabilitiesChanged:
            // These draw no line, so they cannot make a buffer unread. Listed rather than
            // defaulted, so a new event case has to be thought about.
            return .none

        default:
            // Everything with a line and no one speaking: joins, parts, modes, numerics,
            // CTCP, the client's own notices.
            return .activity
        }
    }

    /// Whether `nick` appears in `text` as a word rather than as a fragment.
    ///
    /// `bob` is mentioned by "bob: look at this" and by "thanks, bob!", and is *not*
    /// mentioned by "bobbins". Without the boundary check a short nick highlights on
    /// almost every line, which trains people to ignore the state entirely.
    ///
    /// Prompt 13 owns the configurable keyword and regex lists; this is the one rule that
    /// has to exist for the four states to mean anything.
    static func mentions(_ nick: String, in text: String) -> Bool {
        guard !nick.isEmpty else { return false }
        let haystack = Array(text.lowercased())
        let needle = Array(nick.lowercased())
        guard haystack.count >= needle.count else { return false }

        for start in 0...(haystack.count - needle.count) {
            guard Array(haystack[start..<start + needle.count]) == needle else { continue }
            let before = start > 0 ? haystack[start - 1] : nil
            let afterIndex = start + needle.count
            let after = afterIndex < haystack.count ? haystack[afterIndex] : nil
            if !isNickCharacter(before) && !isNickCharacter(after) { return true }
        }
        return false
    }

    /// Characters that can be part of a nickname, so a match butting up against one is a
    /// fragment rather than a mention. Digits count: `bob2` is not `bob`.
    private static func isNickCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }
}
