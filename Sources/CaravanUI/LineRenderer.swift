import AppKit
import Foundation
import IRCProtocol
import IRCSession

/// What a line needs to know about the moment it is being rendered.
public struct RenderContext: Sendable {
    /// Our own nick, which decides whether a message is an echo of ours.
    public var ownNick: String?

    /// The highest-ranking prefix the sender holds in this channel, e.g. `@`.
    ///
    /// Resolved by the caller, which has the channel snapshot; the renderer has no
    /// business reaching for one.
    public var senderPrefix: Character?

    /// When the line happened. Injectable so a test is not at the mercy of the clock.
    public var now: Date

    public init(ownNick: String? = nil, senderPrefix: Character? = nil, now: Date = Date()) {
        self.ownNick = ownNick
        self.senderPrefix = senderPrefix
        self.now = now
    }
}

/// Turns events into lines for the scrollback.
///
/// mIRC's shape: monospaced, left-aligned, one line per message, `[12:04:22] <bob> text`,
/// wrapping flush-left rather than hanging-indented. The *wording* and the colour both
/// come from ``LineFormatTable`` — one seam, which is what stage 3's Colors dialog and
/// stage 2's themes reach for.
public struct LineRenderer: Sendable {
    public var table: LineFormatTable

    /// A `DateFormatter` pattern, not `strftime`. The default `[HH:mm:ss]` is already
    /// written in that syntax, and the brackets pass through as literals.
    public var timestampFormat: String

    public init(
        table: LineFormatTable = .mIRC,
        timestampFormat: String = ChatSettings.Default.timestampFormat
    ) {
        self.table = table
        self.timestampFormat = timestampFormat
    }

    // MARK: - Building a line

    /// Builds a line from an already-composed string.
    ///
    /// The path for text that is not an event — a usage error, a diagnostic, a raw wire
    /// line — and the one tests use to check styling without constructing an event.
    @MainActor
    public func line(_ text: String, kind: LineKind, now: Date = Date()) -> AttributedString {
        var fields = LineFields()
        fields.text = text
        return line(kind: kind, fields: fields, now: now)
    }

    /// Builds a line from a kind and its fields, through the format table.
    ///
    /// The general entry point. Local self-echo uses it: a message we sent has no event to
    /// describe it, but it has exactly the fields one would have.
    @MainActor
    public func line(kind: LineKind, fields: LineFields, now: Date = Date()) -> AttributedString {
        render(kind: kind, fields: fields, now: now)
    }

    /// The rule marking where the buffer was last left.
    ///
    /// Deliberately longer than any window: the paragraph style it is drawn with clips
    /// rather than wraps, so an over-long rule spans the width whatever the width is,
    /// where a measured one would be wrong the moment the window is resized.
    @MainActor
    public func unreadRule() -> AttributedString {
        line(String(repeating: "─", count: 400), kind: .unreadMarker)
    }

    /// The line for one event, or `nil` when the event is not something to show.
    ///
    /// `.raw` produces none here: it has its own kinds and its own toggle, and rendering
    /// it alongside the interpreted line would double every line in the window.
    @MainActor
    public func line(for event: IRCEvent, context: RenderContext) -> AttributedString? {
        guard let (kind, fields) = describe(event, context: context) else { return nil }
        return render(kind: kind, fields: fields, now: context.now)
    }

    // MARK: - Event to fields

    /// The whole translation table, in one place: which kind a line is, and what fills
    /// its template.
    private func describe(_ event: IRCEvent, context: RenderContext) -> (LineKind, LineFields)? {
        var fields = LineFields()

        switch event {
        case .raw, .namesReply, .endOfNames, .channelChanged, .channelClosed:
            // State and wire traffic. The nick list, the header band and the tree row are
            // where these land; `.raw` has the raw-traffic toggle.
            return nil

        case .message(_, let sender, let text, let kind, let isAction):
            let isOwn = isOwn(sender.nick, context: context)
            fields.nick = decorated(sender, context: context)
            fields.text = text
            switch (kind, isAction) {
            case (.privmsg, true): return (isOwn ? .ownAction : .action, fields)
            case (.privmsg, false): return (isOwn ? .ownMessage : .message, fields)
            case (.notice, _): return (isOwn ? .ownNotice : .notice, fields)
            }

        case .numeric(_, let parameters):
            // Every numeric without a specific event lands here — the MOTD included — so
            // the status window needs no case per code. The first parameter is our own
            // nick, which is noise on every single line.
            fields.text = dropOwnNick(parameters, ownNick: context.ownNick)
                .joined(separator: " ")
            return (.numeric, fields)

        case .registered(let info):
            fields.text = "Registered as \(info.nick)"
            return (.status, fields)

        case .stateChanged(let state):
            guard let text = Self.statusText(for: state) else { return nil }
            fields.text = text
            return (.status, fields)

        case .clientError(let text):
            fields.text = text
            return (.clientError, fields)

        case .joined(let channel, let who):
            fields.nick = who.nick ?? who.wireForm
            fields.userhost = userHost(who)
            fields.channel = channel.raw
            return (.join, fields)

        case .parted(let channel, let who, let reason):
            fields.nick = who.nick ?? who.wireForm
            fields.channel = channel.raw
            fields.reason = parenthesised(reason)
            return (.part, fields)

        case .quit(let who, let reason):
            fields.nick = who.nick ?? who.wireForm
            fields.reason = parenthesised(reason)
            return (.quit, fields)

        case .nickChanged(let who, let newNick):
            fields.nick = who.nick ?? who.wireForm
            fields.text = newNick
            return (.nickChange, fields)

        case .kicked(let channel, let by, let nick, let reason):
            fields.nick = nick
            fields.actor = by.nick ?? by.wireForm
            fields.channel = channel.raw
            fields.reason = parenthesised(reason)
            return (.kick, fields)

        case .topicChanged(let channel, let who, let topic):
            // Three sentences for one kind. A theme can restyle topics; splitting the
            // wording three ways would be three kinds for one event, which is more table
            // than the difference is worth.
            if topic.isEmpty {
                fields.text =
                    who.map { "\($0.nick ?? $0.wireForm) cleared the topic for \(channel)" }
                    ?? "No topic is set for \(channel)"
            } else {
                let attribution = who.map { "\($0.nick ?? $0.wireForm) changed" } ?? "Topic for"
                fields.text = "\(attribution) \(channel): \(topic)"
            }
            return (.topic, fields)

        case .topicAuthor(_, let nick, let setAt):
            let when = setAt.map { " on \(Self.timestamp(epochSeconds: $0))" } ?? ""
            fields.text = "Topic set by \(nick)\(when)"
            return (.topic, fields)

        case .modeChanged(let target, let who, let changes):
            fields.nick = who.map { $0.nick ?? $0.wireForm } ?? "server"
            fields.channel = target.raw
            fields.text = Self.modeDescription(changes)
            return (.mode, fields)

        case .channelModes(let channel, let changes):
            fields.channel = channel.raw
            fields.text = Self.modeDescription(changes)
            return (.channelMode, fields)

        case .joinFailed(let channel, let reason, let text):
            fields.text = "Cannot join \(channel): \(text.isEmpty ? reason.summary : text)"
            return (.clientError, fields)
        }
    }

    // MARK: - Rendering

    @MainActor
    private func render(kind: LineKind, fields: LineFields, now: Date) -> AttributedString {
        var fields = fields
        fields.timestamp = formattedTimestamp(now)

        let format = table[kind]
        let (text, timestampRange) = format.expand(fields)

        var attributed = AttributedString(text)
        attributed.foregroundColor = format.colour.nsColor
        // No font here: `NSFont` is not `Sendable`, so Swift 6 will not let one into an
        // `AttributedString`. `MessageLogController` fills in the chat font and the
        // paragraph style on the AppKit side, over runs that do not set their own.

        // The timestamp is dim whatever the line is, so the eye skips over it.
        if let timestampRange,
            let lower = AttributedString.Index(timestampRange.lowerBound, within: attributed),
            let upper = AttributedString.Index(timestampRange.upperBound, within: attributed)
        {
            attributed[lower..<upper].foregroundColor = LineColour.dim.nsColor
        }

        if text.contains("://") || text.contains("www.") {
            applyLinks(to: &attributed, in: text)
        }
        return attributed
    }

    /// The timestamp exactly as a line would carry it, for the settings form's preview.
    ///
    /// The preview has to be the real thing rather than an approximation of it, or a
    /// format that renders differently in the buffer than in the form is a bug the form
    /// itself hides.
    public func timestampPreview(_ date: Date = Date()) -> String {
        formattedTimestamp(date).trimmingCharacters(in: .whitespaces)
    }

    /// The timestamp column, with its trailing space, or nothing at all.
    ///
    /// Fixed width by construction: a monospaced font plus a fixed-width format means the
    /// message text forms a clean left edge without any column arithmetic.
    private func formattedTimestamp(_ date: Date) -> String {
        guard !timestampFormat.isEmpty else { return "" }
        return Self.formatter(for: timestampFormat).string(from: date) + " "
    }

    /// `<@bob>` — the nick with the highest-ranking prefix it holds in this channel.
    private func decorated(_ source: IRCSource, context: RenderContext) -> String {
        let nick = source.nick ?? source.wireForm
        guard let prefix = context.senderPrefix else { return nick }
        return "\(prefix)\(nick)"
    }

    private func isOwn(_ nick: String?, context: RenderContext) -> Bool {
        guard let nick, let ownNick = context.ownNick else { return false }
        // A plain case-insensitive compare: the server echoes our nick in the form it
        // holds, so the casemapping subtleties that matter for dictionary keys do not
        // arise here.
        return nick.lowercased() == ownNick.lowercased()
    }

    private func userHost(_ source: IRCSource) -> String {
        guard case .user(_, let user, let host) = source else { return "" }
        return "\(user ?? "")@\(host ?? "")"
    }

    private func parenthesised(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "" }
        return " (\(reason))"
    }

    /// Numerics repeat our nick as their first parameter. Showing it on every MOTD line
    /// is pure noise.
    private func dropOwnNick(_ parameters: [String], ownNick: String?) -> [String] {
        guard let ownNick, parameters.first == ownNick else { return parameters }
        return Array(parameters.dropFirst())
    }

    // MARK: - Shared helpers

    /// A human sentence for a lifecycle change, or `nil` for the ones with nothing to
    /// say. The disconnect *reason* is always included: "disconnected" on its own throws
    /// away the only thing the user wants to know.
    static func statusText(for state: SessionState) -> String? {
        switch state {
        case .connecting:
            return "Connecting..."
        case .registering:
            return "Connected, registering..."
        case .connected:
            return nil  // `.registered` already said so, with the nick.
        case .reconnecting(let attempt, let delay):
            let seconds =
                Double(delay.components.seconds)
                + Double(delay.components.attoseconds) / 1e18
            return "Reconnecting (attempt \(attempt)) in \(String(format: "%.1f", seconds))s"
        case .disconnected(let reason):
            switch reason {
            case .notStarted: return nil
            case .userInitiated: return "Disconnected"
            case .serverError(let text): return "Disconnected: server said \(text)"
            case .transportFailed(let error): return "Disconnected: \(error)"
            case .registrationFailed(let text): return "Registration failed: \(text)"
            case .timedOut: return "Disconnected: the connection stopped responding"
            case .connectTimedOut: return "Could not connect: timed out"
            }
        }
    }

    /// The same words with the `***` the status template adds, for callers that need a
    /// plain string rather than a rendered line.
    public static func statusLine(for state: SessionState) -> String? {
        statusText(for: state).map { "*** \($0)" }
    }

    /// `+on-v carol dave`, with the signs collapsed the way a server writes them.
    static func modeDescription(_ changes: [ModeChange]) -> String {
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
    static func timestamp(epochSeconds: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
            .formatted(date: .abbreviated, time: .shortened)
    }

    /// Formatters are expensive to build and this runs per line, so they are cached by
    /// pattern. One pattern exists over a session, in practice.
    private static let formatterCache = FormatterCache()

    private static func formatter(for pattern: String) -> DateFormatter {
        formatterCache.formatter(for: pattern)
    }

    @MainActor
    private func applyLinks(to attributed: inout AttributedString, in text: String) {
        guard let detector = Self.linkDetector else { return }
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

/// A lock-guarded cache, because `DateFormatter` is not `Sendable` and building one per
/// rendered line is measurable at the rates this scrollback is built for.
private final class FormatterCache: @unchecked Sendable {
    // @unchecked: every access to `formatters` happens inside `lock`, which is the
    // invariant the compiler cannot see. Nothing else touches the storage.
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func formatter(for pattern: String) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = formatters[pattern] { return existing }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        formatters[pattern] = formatter
        return formatter
    }
}
