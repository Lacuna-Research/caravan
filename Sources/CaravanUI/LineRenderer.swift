import AppKit
import Foundation
import IRCProtocol
import IRCSession

/// What a rendered line is *about*, which is all the styling stage 1 needs.
///
/// Prompt 10 replaces this with the full set — own message, action, join/part, kick,
/// mode, topic, nick change — and puts the colours in one table so stage 2 theming has a
/// single seam. This is that table, small.
public enum LineKind: Sendable, Hashable {
    case message
    case notice
    case serverText
    case clientError
    case status

    var colour: NSColor {
        switch self {
        case .message: .labelColor
        case .notice: .systemPurple
        case .serverText: .secondaryLabelColor
        case .clientError: .systemRed
        case .status: .systemTeal
        }
    }
}

/// Turns events into lines for the scrollback.
///
/// Deliberately plain at this stage: monospaced, left-aligned, one line per message, in
/// the shape mIRC used — `<nick> text`. Timestamps, the full set of line kinds and their
/// colours are prompt 10's, and land in ``LineKind`` rather than here.
public enum LineRenderer {
    /// Monospaced, because IRC is full of tables, ASCII art and aligned output that
    /// proportional text destroys.
    /// Computed rather than stored: a `static let` of a non-`Sendable` AppKit type is
    /// global mutable state as far as Swift 6 is concerned. AppKit caches fonts, so this
    /// is not a per-line allocation.
    @MainActor public static var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    /// Builds a styled line.
    @MainActor
    public static func line(_ text: String, kind: LineKind = .serverText) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = kind.colour
        // No font here: `NSFont` is not `Sendable`, so Swift 6 will not let it into an
        // `AttributedString`. ``MessageLogController`` applies the default font to runs
        // that lack one, which leaves prompt 10 free to set bold or italic per run.
        if text.contains("://") || text.contains("www.") {
            applyLinks(to: &attributed, in: text)
        }
        return attributed
    }

    /// The line for one event, or `nil` when the event is not something to show.
    ///
    /// Every *displayable* event produces exactly one line. `.raw` produces none here:
    /// showing it as well would double every line in the window. Prompt 10 gives it a
    /// home behind the raw-traffic toggle, which is what the `.raw` guarantee is for.
    @MainActor
    public static func line(for event: IRCEvent, ownNick: String?) -> AttributedString? {
        switch event {
        case .raw:
            return nil

        case .message(_, let sender, let text, let kind, let isAction):
            let nick = senderName(sender)
            if isAction {
                return line("* \(nick) \(text)", kind: .message)
            }
            switch kind {
            case .privmsg:
                return line("<\(nick)> \(text)", kind: .message)
            case .notice:
                // mIRC's notice form, and the reason notices are visibly not messages.
                return line("-\(nick)- \(text)", kind: .notice)
            }

        case .numeric(_, let parameters):
            // Every numeric without a specific event lands here — the MOTD included — so
            // the status window needs no case per code. The first parameter is our own
            // nick, which is noise on every single line.
            let interesting = dropOwnNick(parameters, ownNick: ownNick)
            return line(interesting.joined(separator: " "), kind: .serverText)

        case .registered(let info):
            return line("*** Registered as \(info.nick)", kind: .status)

        case .stateChanged(let state):
            return statusLine(for: state).map { line($0, kind: .status) }

        case .clientError(let text):
            return line("*** \(text)", kind: .clientError)

        case .joined(let channel, let who):
            return line(
                "*** Joins: \(senderName(who)) (\(userHost(who))) \(channel)",
                kind: .status
            )

        case .parted(let channel, let who, let reason):
            let suffix = reason.map { " (\($0))" } ?? ""
            return line("*** Parts: \(senderName(who)) \(channel)\(suffix)", kind: .status)

        case .quit(let who, let reason):
            let suffix = reason.map { " (\($0))" } ?? ""
            return line("*** Quits: \(senderName(who))\(suffix)", kind: .status)

        case .nickChanged(let who, let newNick):
            return line("*** \(senderName(who)) is now known as \(newNick)", kind: .status)

        case .kicked(let channel, let by, let nick, let reason):
            let suffix = reason.map { " (\($0))" } ?? ""
            return line(
                "*** \(nick) was kicked from \(channel) by \(senderName(by))\(suffix)",
                kind: .status
            )

        case .topicChanged(let channel, let who, let topic):
            guard !topic.isEmpty else {
                // 331, and a `TOPIC` that cleared one. Both are "there is no topic", and
                // rendering an empty string after a colon says that badly.
                let attribution =
                    who.map { "\(senderName($0)) cleared the topic for" } ?? "No topic is set for"
                return line("*** \(attribution) \(channel)", kind: .status)
            }
            let attribution = who.map { "\(senderName($0)) changed" } ?? "Topic for"
            return line("*** \(attribution) \(channel): \(topic)", kind: .status)

        case .topicAuthor(_, let nick, let setAt):
            let when = setAt.map { " on \(timestamp(epochSeconds: $0))" } ?? ""
            return line("*** Topic set by \(nick)\(when)", kind: .status)

        case .modeChanged(let target, let who, let changes):
            let attribution = who.map(senderName) ?? "server"
            return line(
                "*** \(attribution) sets mode: \(modeDescription(changes)) on \(target)",
                kind: .status
            )

        case .channelModes(let channel, let changes):
            return line(
                "*** Channel modes for \(channel): \(modeDescription(changes))",
                kind: .status
            )

        case .joinFailed(let channel, let reason, let text):
            // A join failure is something the user can act on — supply a key, get an
            // invite — so it reads as our error rather than as another server numeric.
            return line(
                "*** Cannot join \(channel): \(text.isEmpty ? reason.summary : text)",
                kind: .clientError
            )

        case .namesReply, .endOfNames:
            // The nick list is the visible form of these. Printing every 353 batch into
            // the buffer as well would repeat, line by line, what the pane already shows.
            return nil

        case .channelChanged, .channelClosed:
            // State, not a thing that happened. The nick list, header band and tree row
            // are where these land.
            return nil
        }
    }

    /// `+o alice -v bob`, with the signs collapsed the way a server writes them.
    private static func modeDescription(_ changes: [ModeChange]) -> String {
        guard !changes.isEmpty else { return "" }
        var letters = ""
        var arguments: [String] = []
        var sign: Bool?
        for change in changes {
            if sign != change.isSet {
                letters.append(change.isSet ? "+" : "-")
                sign = change.isSet
            }
            letters.append(change.mode)
            if let argument = change.argument { arguments.append(argument) }
        }
        return ([letters] + arguments).joined(separator: " ")
    }

    /// 333's Unix epoch seconds, in the user's own locale and time zone.
    private static func timestamp(epochSeconds: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
            .formatted(date: .abbreviated, time: .shortened)
    }

    /// A human sentence for a lifecycle change, or `nil` for the ones with nothing to
    /// say. The disconnect *reason* is always included: "disconnected" on its own throws
    /// away the only thing the user wants to know.
    static func statusLine(for state: SessionState) -> String? {
        switch state {
        case .connecting:
            return "*** Connecting..."
        case .registering:
            return "*** Connected, registering..."
        case .connected:
            return nil  // `.registered` already said so, with the nick.
        case .reconnecting(let attempt, let delay):
            let seconds =
                Double(delay.components.seconds)
                + Double(delay.components.attoseconds) / 1e18
            return "*** Reconnecting (attempt \(attempt)) in \(String(format: "%.1f", seconds))s"
        case .disconnected(let reason):
            switch reason {
            case .notStarted: return nil
            case .userInitiated: return "*** Disconnected"
            case .serverError(let text): return "*** Disconnected: server said \(text)"
            case .transportFailed(let error): return "*** Disconnected: \(error)"
            case .registrationFailed(let text): return "*** Registration failed: \(text)"
            case .timedOut: return "*** Disconnected: the connection stopped responding"
            case .connectTimedOut: return "*** Could not connect: timed out"
            }
        }
    }

    private static func senderName(_ source: IRCSource) -> String {
        switch source {
        case .server(let name): name
        case .user(let nick, _, _): nick
        }
    }

    private static func userHost(_ source: IRCSource) -> String {
        guard case .user(_, let user, let host) = source else { return "" }
        return "\(user ?? "")@\(host ?? "")"
    }

    /// Numerics repeat our nick as their first parameter. Showing it on every MOTD line
    /// is pure noise.
    private static func dropOwnNick(_ parameters: [String], ownNick: String?) -> [String] {
        guard let ownNick, parameters.first == ownNick else { return parameters }
        return Array(parameters.dropFirst())
    }

    @MainActor
    private static func applyLinks(to attributed: inout AttributedString, in text: String) {
        guard let detector = linkDetector else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url,
                let stringRange = Range(match.range, in: text),
                let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].link = url
        }
    }

    /// Built once: `NSDataDetector` is expensive to construct and this runs per line.
    @MainActor
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
}
