import Foundation

/// One thing somebody said, reduced to what makes it the same thing said twice.
///
/// Two keys, and which one is available decides which is used:
///
/// - **`msgid`**, where the sender's network supplies one. Exact, and the only key that
///   survives a clock disagreeing with itself.
/// - **`(stamp, nick, text)`** otherwise, with the stamp to the second and carrying its
///   date. This is the key a *log line* can offer: a plain-text log has nowhere to put a
///   message id, and adding a sidecar file to hold one would mean the log was no longer the
///   plain text this feature promises. Because the stamp carries the date, a false positive
///   needs the same person to say the same words in the same second — which is not a false
///   positive, it is the duplicate being removed.
///
/// The nick is stored undecorated. A logged line reads `<@bob>` if bob held op when it was
/// written, and the replay of it reads `<bob>` if he has since lost it; the prefix is a
/// property of the moment it was rendered rather than of the message.
public struct ReplayKey: Hashable, Sendable {
    public var msgid: String?
    public var stamp: String
    public var nick: String
    public var text: String

    public init(msgid: String? = nil, stamp: String, nick: String, text: String) {
        self.msgid = msgid.flatMap { $0.isEmpty ? nil : $0 }
        self.stamp = stamp
        self.nick = ReplayKey.undecorated(nick)
        self.text = text
    }

    public init(msgid: String? = nil, date: Date, nick: String, text: String) {
        self.init(msgid: msgid, stamp: ChatLog.stamp(date), nick: nick, text: text)
    }

    /// `@bob` back to `bob`.
    ///
    /// The membership prefixes and nothing else. A nick may legitimately begin with
    /// `[ \ ] ^ _ { | }` — RFC 2812 says so — and stripping a guessed class of punctuation
    /// would key `|bob|` and `bob|` as the same person.
    static func undecorated(_ nick: String) -> String {
        guard let first = nick.first, "~&@%+!".contains(first) else { return nick }
        return String(nick.dropFirst())
    }

    /// Whether this key and another name the same line.
    ///
    /// The `msgid` decides it *when both have one*: two lines that each carry an id and
    /// disagree about it are two lines, whatever else matches. Where either side is without
    /// one — a line read back from the log always is — the triple decides.
    func matches(_ other: ReplayKey) -> Bool {
        if let mine = msgid, let theirs = other.msgid { return mine == theirs }
        return stamp == other.stamp && nick == other.nick && text == other.text
    }
}

/// The lines a buffer already holds, so a `chathistory` replay of the same period does not
/// arrive as a second copy of it.
///
/// **Seeded from both sources, which is the property that makes it work.** The reloaded tail
/// of the log goes in, and so does every line appended live — so the overlap the bouncer
/// backfills is recognised whether the client saw it last week or four minutes ago.
///
/// **A hit consumes its entry.** Somebody who says "lol" twice in one second has said two
/// things and should see two lines; leaving the entry in place would collapse them, and a
/// de-duplicator that eats real messages is worse than the duplicate it prevents.
@MainActor
public final class ReplayIndex {
    /// How many keys are kept. Bounded for the same reason the scrollback is: a client left
    /// open for a week must not grow without limit. Comfortably more than any reload count
    /// or `chatHistoryLimit`, which is what it has to span.
    public var cap: Int {
        didSet { trim() }
    }

    /// Oldest first, which is the end trimming takes from.
    private var keys: [ReplayKey] = []

    public init(cap: Int = 500) {
        self.cap = cap
    }

    public var count: Int { keys.count }

    public func remember(_ key: ReplayKey) {
        keys.append(key)
        trim()
    }

    /// Whether `key` names a line already held — and if it does, forgets it.
    public func consume(_ key: ReplayKey) -> Bool {
        guard let index = keys.firstIndex(where: { $0.matches(key) }) else { return false }
        keys.remove(at: index)
        return true
    }

    public func clear() {
        keys.removeAll()
    }

    private func trim() {
        guard keys.count > cap else { return }
        keys.removeFirst(keys.count - cap)
    }
}

/// One line read back out of a log file.
///
/// Parsed only as far as the de-duplicator and the viewer need: the stamp, and — for the
/// three line shapes a `chathistory` replay can produce — who said it and what they said.
/// An event line (`*** Joins: …`) is carried whole with no key, which is correct rather
/// than incomplete: `chathistory` replays messages, so a logged join has nothing to collide
/// with.
public struct LoggedLine: Hashable, Sendable {
    /// The line exactly as written, stamp and all. What the buffer shows on reload.
    public var text: String

    /// The moment in the stamp, or `nil` for a line that has none — a hand-appended note,
    /// or a log written by something else.
    public var date: Date?

    /// The de-duplication key, for the shapes that have one.
    public var key: ReplayKey?

    /// Parses one line.
    public init(_ line: String) {
        self.text = line
        guard line.hasPrefix("["),
            let close = line.firstIndex(of: "]"),
            case let stamp = String(line[line.index(after: line.startIndex)..<close]),
            stamp.count == ChatLog.stampWidth,
            let date = ChatLog.date(fromStamp: stamp)
        else { return }
        self.date = date

        var rest = line[line.index(after: close)...]
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        guard let (nick, message) = Self.speaker(in: rest) else { return }
        self.key = ReplayKey(stamp: stamp, nick: nick, text: message)
    }

    /// Who said it, for the three templates that put a speaker in a column.
    ///
    /// `<bob> hi`, `* bob waves` and `-bob- hi` — ``LineKind/message``, ``LineKind/action``
    /// and ``LineKind/notice``, with their `own*` twins, which between them are everything
    /// a replay can send. `*** Joins:` is deliberately not one: it opens with three stars
    /// where an action opens with one, which is what tells them apart.
    private static func speaker(in rest: Substring) -> (String, String)? {
        if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            let nick = String(rest[rest.index(after: rest.startIndex)..<close])
            return (nick, String(rest[close...].dropFirst().drop(while: { $0 == " " })))
        }
        if rest.hasPrefix("* "), !rest.hasPrefix("** ") {
            let body = rest.dropFirst(2)
            guard let space = body.firstIndex(of: " ") else { return nil }
            return (String(body[..<space]), String(body[space...].dropFirst()))
        }
        if rest.hasPrefix("-"), let close = rest.dropFirst().firstIndex(of: "-") {
            let nick = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !nick.isEmpty else { return nil }
            return (nick, String(rest[close...].dropFirst().drop(while: { $0 == " " })))
        }
        return nil
    }
}
