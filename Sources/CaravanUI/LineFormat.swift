import AppKit

/// What a rendered line is *about*. One case per thing the buffer can say.
///
/// The `own*` cases are the internal mark the prompt asks for: with no `echo-message`
/// capability we echo our own messages locally, and when stage 2 negotiates it the server
/// starts echoing them back instead. Being able to tell "this line came from us" apart
/// from "this line came from the server" is what makes suppressing the duplicate a filter
/// rather than an archaeology project.
public enum LineKind: String, Sendable, Hashable, CaseIterable {
    case message
    case ownMessage
    case action
    case ownAction
    case notice
    case ownNotice
    /// A message we sent *somewhere else*, echoed in the window we typed it in.
    ///
    /// `/msg bob hi` typed in `#swift` has to be visibly not a line in `#swift`. Rendered
    /// `-> *bob* hi`, as mIRC has for decades: the nick in the column is the recipient,
    /// not the sender, and the arrow is what says so.
    case ownPrivateMessage
    /// The same, for `/notice`.
    case ownPrivateNotice
    case join
    case part
    case quit
    case kick
    case mode
    /// 324's reply, which names no one — a different sentence from a mode *change*.
    case channelMode
    case topic
    case nickChange
    case numeric
    case clientError
    case status
    /// A line the server sent, shown by the raw-traffic toggle.
    case rawInbound
    /// A line we sent, shown by the raw-traffic toggle.
    case rawOutbound
    /// The horizontal rule marking where you last left the buffer.
    case unreadMarker

    /// Whether this line is our own words coming back to us.
    ///
    /// The one question stage 2 needs to ask when `echo-message` arrives.
    public var isSelfEcho: Bool {
        switch self {
        case .ownMessage, .ownAction, .ownNotice, .ownPrivateMessage, .ownPrivateNotice: true
        default: false
        }
    }

    /// Whether `$nick` names a speaker in a column, rather than a person mid-sentence.
    ///
    /// Nick colouring applies only here. An event line mentions people inside a sentence —
    /// "*** Joins: bob" — and colouring those turns the event stream into a ransom note
    /// while stealing the one signal that says "somebody said this".
    public var hasNickColumn: Bool {
        switch self {
        case .message, .ownMessage, .action, .ownAction, .notice, .ownNotice,
            .ownPrivateMessage, .ownPrivateNotice:
            true
        default:
            false
        }
    }
}

/// A line's colour, named by role rather than by value.
///
/// Semantic rather than RGB so the system's own colours can adapt to light and dark
/// without a table per appearance. Stage 3's Colors dialog makes these user-editable;
/// stage 2's palette work adds the mIRC colour indices beside them.
/// The raw values name the role on the wire between the renderer and the buffer — a
/// ``NickColumn`` carries one so the nick can be put back in its line's colour.
public enum LineColour: String, Sendable, Hashable {
    case text
    case ownText
    case dim
    case notice
    case action
    case event
    case error
    /// The unread rule. The accent colour, so it is findable and follows the user's own
    /// choice, and so it is not one more thing overloaded onto red.
    case marker

    @MainActor
    var nsColor: NSColor {
        switch self {
        case .text: .labelColor
        case .ownText: .systemGray
        case .dim: .tertiaryLabelColor
        case .notice: .systemPurple
        case .action: .systemPink
        case .event: .systemTeal
        case .error: .systemRed
        case .marker: .controlAccentColor
        }
    }
}

/// How one kind of line is written and coloured.
///
/// **One seam, holding both.** The template is a string with `$variable` placeholders and
/// the colour is a role; between them they are everything a theme needs to change, which
/// is why they live in one table rather than two. No JavaScript on the render path — a JS
/// call per line cannot hit the ingest target, and the opt-in hook for computed
/// formatting is stage 3's, beside scripting.
public struct LineFormat: Sendable, Hashable {
    /// A template such as `"$timestamp<$nick> $text"`.
    ///
    /// `$timestamp` expands to the formatted time *and its trailing space*, or to nothing
    /// at all when timestamps are off — so a template need not know which.
    public var template: String
    public var colour: LineColour

    public init(template: String, colour: LineColour) {
        self.template = template
        self.colour = colour
    }
}

/// The format table: one entry per ``LineKind``.
///
/// mIRC's conventions, because they are what forty years of muscle memory reads without
/// thinking: `*** Joins: nick (user@host)`, `* nick does something`, `-nick- notice`.
public struct LineFormatTable: Sendable {
    private var formats: [LineKind: LineFormat]

    public init(formats: [LineKind: LineFormat]) {
        self.formats = formats
    }

    public subscript(kind: LineKind) -> LineFormat {
        formats[kind] ?? LineFormat(template: "$timestamp$text", colour: .text)
    }

    public static let mIRC = LineFormatTable(formats: [
        .message: LineFormat(template: "$timestamp<$nick> $text", colour: .text),
        .ownMessage: LineFormat(template: "$timestamp<$nick> $text", colour: .ownText),
        .action: LineFormat(template: "$timestamp* $nick $text", colour: .action),
        .ownAction: LineFormat(template: "$timestamp* $nick $text", colour: .action),
        .notice: LineFormat(template: "$timestamp-$nick- $text", colour: .notice),
        .ownNotice: LineFormat(template: "$timestamp-$nick- $text", colour: .notice),
        .ownPrivateMessage: LineFormat(
            template: "$timestamp-> *$nick* $text",
            colour: .ownText
        ),
        .ownPrivateNotice: LineFormat(
            template: "$timestamp-> -$nick- $text",
            colour: .notice
        ),
        .join: LineFormat(
            template: "$timestamp*** Joins: $nick ($userhost) $channel",
            colour: .event
        ),
        .part: LineFormat(template: "$timestamp*** Parts: $nick $channel$reason", colour: .event),
        .quit: LineFormat(template: "$timestamp*** Quits: $nick$reason", colour: .event),
        .kick: LineFormat(
            template: "$timestamp*** $nick was kicked from $channel by $actor$reason",
            colour: .event
        ),
        .mode: LineFormat(template: "$timestamp*** $nick sets mode: $text", colour: .event),
        .channelMode: LineFormat(
            template: "$timestamp*** Channel modes for $channel: $text",
            colour: .event
        ),
        .topic: LineFormat(template: "$timestamp*** $text", colour: .event),
        .nickChange: LineFormat(
            template: "$timestamp*** $nick is now known as $text",
            colour: .event
        ),
        .numeric: LineFormat(template: "$timestamp$text", colour: .dim),
        .clientError: LineFormat(template: "$timestamp*** $text", colour: .error),
        .status: LineFormat(template: "$timestamp*** $text", colour: .event),
        .rawInbound: LineFormat(template: "$timestamp<< $text", colour: .dim),
        .rawOutbound: LineFormat(template: "$timestamp>> $text", colour: .dim),
        // No timestamp: the rule marks a position, not a moment.
        .unreadMarker: LineFormat(template: "$text", colour: .marker),
    ])
}

/// The values a template can refer to.
///
/// Deliberately few. Every one of them is something a line actually has, and a variable
/// that is absent expands to nothing rather than to its own name — a theme that mentions
/// `$channel` in a quit line should produce a slightly odd sentence, not the word
/// "$channel".
public struct LineFields: Sendable {
    public var timestamp: String = ""
    public var nick: String = ""
    public var text: String = ""
    public var channel: String = ""
    public var userhost: String = ""
    public var actor: String = ""
    public var reason: String = ""

    public init() {}

    subscript(name: String) -> String? {
        switch name {
        case "timestamp": timestamp
        case "nick": nick
        case "text": text
        case "channel": channel
        case "userhost": userhost
        case "actor": actor
        case "reason": reason
        default: nil
        }
    }
}

extension LineFormat {
    /// Where each field landed in the expanded line.
    ///
    /// The ranges come back because three things are styled independently of the line's
    /// own colour — the timestamp is dimmed, the nick takes its hash colour, and the
    /// message text carries whatever inline formatting the sender sent — and finding any
    /// of them again by searching the output would be guesswork the moment a nick contains
    /// the same characters as the text.
    struct Expansion {
        var text: String
        var ranges: [String: Range<String.Index>] = [:]

        subscript(field: String) -> Range<String.Index>? { ranges[field] }
    }

    /// Expands the template, reporting where each field ended up.
    func expand(_ fields: LineFields) -> Expansion {
        var output = ""
        var ranges: [String: Range<String.Index>] = [:]
        var rest = Substring(template)

        while let dollar = rest.firstIndex(of: "$") {
            output += rest[rest.startIndex..<dollar]
            let afterDollar = rest.index(after: dollar)
            let nameEnd =
                rest[afterDollar...].firstIndex { !$0.isLetter } ?? rest.endIndex
            let name = String(rest[afterDollar..<nameEnd])

            if let value = fields[name] {
                let start = output.endIndex
                output += value
                if !value.isEmpty {
                    ranges[name] = start..<output.endIndex
                }
            } else {
                // Not a variable at all — a literal `$` in the template, or a name this
                // build does not know. Kept as written rather than swallowed.
                output.append("$")
                output += name
            }
            rest = rest[nameEnd...]
        }
        output += rest
        return Expansion(text: output, ranges: ranges)
    }
}
