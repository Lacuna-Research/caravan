import AppKit
import Foundation
import IRCFormat
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

    /// Which colours the indices in a sender's `^C` codes resolve to, and whether nicks
    /// are coloured at all.
    public var palette: Palette

    public init(
        table: LineFormatTable = .mIRC,
        timestampFormat: String = ChatSettings.Default.timestampFormat,
        palette: Palette = Palette()
    ) {
        self.table = table
        self.timestampFormat = timestampFormat
        self.palette = palette
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
        return render(
            kind: kind,
            fields: fields,
            now: context.now,
            senderPrefix: context.senderPrefix
        )
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

        case .batchStarted, .batchEnded, .bouncerNetworks:
            // Structure, not content. A batch's lines are what gets rendered, and the
            // bouncer's network list is a shape the *tree* takes rather than a line.
            return nil

        case .message(_, let sender, let text, let kind, let isAction, _):
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

        case .clientNotice(let text):
            fields.text = text
            return (.status, fields)

        case .joined(let channel, let who, _, _):
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

        case .capabilitiesChanged(let capabilities):
            // Worth a line, once per connection: which capabilities are on decides whether
            // your own messages come from the server, whether timestamps are the server's,
            // and whether the nick list knows who is away. When something later behaves
            // unexpectedly this line is the first thing to check.
            let names = capabilities.enabledNames
            fields.text =
                names.isEmpty
                ? "No IRCv3 capabilities negotiated"
                : "Capabilities: \(names.joined(separator: " "))"
            return (.status, fields)

        case .authenticated(let account):
            fields.text = "Authenticated as \(account)"
            return (.status, fields)

        case .standardReply(let reply):
            fields.text = "\(reply.command): \(reply.summary)"
            return (reply.severity == .fail ? .clientError : .serverNotice, fields)

        case .awayChanged(let who, let message):
            fields.nick = who.nick ?? who.wireForm
            fields.text = message.map { "is away: \($0)" } ?? "is back"
            return (.away, fields)

        case .accountChanged(let who, let account):
            fields.nick = who.nick ?? who.wireForm
            fields.text = account.map { "is logged in as \($0)" } ?? "logged out"
            return (.account, fields)

        case .hostChanged(let who, let user, let host):
            fields.nick = who.nick ?? who.wireForm
            fields.userhost = "\(user)@\(host)"
            return (.hostChange, fields)

        case .realNameChanged(let who, let realName):
            fields.nick = who.nick ?? who.wireForm
            fields.text = realName
            return (.realNameChange, fields)

        case .invited(let by, let nick, let channel):
            // Two sentences, one kind: an invitation aimed at us reads as an offer, and
            // one we merely witnessed reads as news about someone else.
            let isOurs = isOwn(nick, context: context)
            if let by {
                let inviter = by.nick ?? by.wireForm
                fields.text =
                    isOurs
                    ? "\(inviter) invites you to \(channel)"
                    : "\(inviter) invites \(nick) to \(channel)"
            } else {
                fields.text = "Invited \(nick) to \(channel)"
            }
            return (.invite, fields)
        }
    }

    // MARK: - Rendering

    @MainActor
    private func render(
        kind: LineKind,
        fields: LineFields,
        now: Date,
        senderPrefix: Character? = nil
    ) -> AttributedString {
        var fields = fields
        fields.timestamp = formattedTimestamp(now)

        // The codes come out of the text before the template ever sees it, so a `$text`
        // holding a `^C` cannot shift the columns the rest of the line is measured in.
        let formatted = IRCFormatting.parse(fields.text)
        fields.text = formatted.plain
        fields.nick = IRCFormatting.stripping(fields.nick)

        let format = table[kind]
        let expansion = format.expand(fields)
        let text = expansion.text

        var attributed = AttributedString(text)
        attributed.foregroundColor = format.colour.nsColor
        // No font here: `NSFont` is not `Sendable`, so Swift 6 will not let one into an
        // `AttributedString`. `MessageLogController` fills in the chat font and the
        // paragraph style on the AppKit side, over runs that do not set their own.

        // The timestamp is dim whatever the line is, so the eye skips over it.
        if let range = attributedRange(expansion["timestamp"], in: attributed, text: text) {
            attributed[range].foregroundColor = LineColour.dim.nsColor
        }

        // The nick wears its own colour, over the line's. Only where there is a nick
        // *column* — an event line names people mid-sentence, and colouring those turns a
        // join into a ransom note.
        if kind.hasNickColumn, !fields.nick.isEmpty,
            let range = attributedRange(expansion["nick"], in: attributed, text: text)
        {
            let nick = Self.undecorated(fields.nick, prefix: senderPrefix)
            // Recorded whether or not it is coloured right now, so turning the setting on
            // or off reaches the buffer rather than only the next line to arrive.
            attributed[range].nickColumn = NickColumn(nick: nick, base: format.colour)
            if let colour = palette.colour(forNick: nick) {
                attributed[range].foregroundColor = colour
            }
        }

        if !formatted.isPlain, let textRange = expansion["text"] {
            apply(formatted, to: &attributed, at: textRange, in: text)
        }

        if text.contains("://") || text.contains("www.") {
            applyLinks(to: &attributed, in: text)
        }
        return attributed
    }

    /// Lays the sender's inline formatting over the stretch of the line their text became.
    ///
    /// Walked as offsets from the start of that stretch rather than searched for: the same
    /// word appears twice in a sentence often enough that finding it by content would
    /// eventually style the wrong one.
    @MainActor
    private func apply(
        _ formatted: FormattedText,
        to attributed: inout AttributedString,
        at textRange: Range<String.Index>,
        in text: String
    ) {
        var cursor = textRange.lowerBound
        for run in formatted.runs {
            let end = text.index(cursor, offsetBy: run.text.count, limitedBy: textRange.upperBound)
            guard let end else { return }
            defer { cursor = end }
            guard !run.style.isPlain,
                let range = attributedRange(cursor..<end, in: attributed, text: text)
            else { continue }

            let style = run.style
            var (foreground, background) = palette.colours(
                foreground: style.foreground,
                background: style.background
            )
            // `^R` swaps the two, and where one is absent it swaps in the window's own
            // colours — which is why it is resolved here rather than in the pure module.
            if style.isReversed {
                let swapped = (
                    background ?? NSColor.textBackgroundColor, foreground ?? NSColor.textColor
                )
                (foreground, background) = swapped
            }

            if let foreground { attributed[range].foregroundColor = foreground }
            if let background { attributed[range].backgroundColor = background }
            if style.isUnderlined { attributed[range].underlineStyle = Self.singleLine }
            if style.isStruckThrough { attributed[range].strikethroughStyle = Self.singleLine }
            // Bold, italic and monospace are traits of the *font*, and a font cannot go
            // into an `AttributedString` under Swift 6. They travel as an attribute
            // `MessageLogController` reads when it fills in the chat font.
            attributed[range].inlineTraits = InlineTraits(style: style)
        }
    }

    /// **Typed, not a bare `.single`.** `underlineStyle` and `strikethroughStyle` exist in
    /// both the AppKit and the SwiftUI attribute scopes, and a bare `.single` picks
    /// SwiftUI's `Text.LineStyle` — which `NSAttributedString` has no key for and drops
    /// on the way into the text storage. Naming the type picks AppKit's, which is the one
    /// the text view can actually draw.
    private static let singleLine: NSUnderlineStyle = .single

    /// The `AttributedString` range matching a `String` range, or `nil` if it does not
    /// convert — which it will not for an index inside a grapheme cluster.
    private func attributedRange(
        _ range: Range<String.Index>?,
        in attributed: AttributedString,
        text: String
    ) -> Range<AttributedString.Index>? {
        guard let range,
            let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { return nil }
        return lower..<upper
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

    /// `@bob` back to `bob`, given the prefix the caller decorated it with.
    ///
    /// The nick column shows the prefix the sender holds here, but the colour hash is
    /// seeded on the name alone (§6) — so hashing the decorated form would give the same
    /// person one colour in a channel where he is opped and another where he is not.
    /// Undecorated with the character the caller actually used rather than by stripping
    /// a guessed class of punctuation: a server declares its own `PREFIX`, and the
    /// resolved one is already in hand.
    static func undecorated(_ nick: String, prefix: Character?) -> String {
        guard let prefix, nick.first == prefix else { return nick }
        return String(nick.dropFirst())
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
            case .authenticationFailed(let text): return "Authentication failed: \(text)"
            case .trustRefused:
                // Says whose decision it was. The TLS error underneath this reads
                // "-9808: bad certificate format", which sounds like a broken server.
                return "Not connected: the server's certificate was not trusted"
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
