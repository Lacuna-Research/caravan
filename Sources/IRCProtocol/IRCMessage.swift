/// A parsed IRC protocol message.
///
/// Pure value type. Parsing never fails on malformed input beyond an entirely empty
/// command — a client that refuses to represent a weird line cannot show it to the
/// user, and showing it is the whole point of the status window.
public struct IRCMessage: Sendable, Hashable {
    public var tags: IRCTags
    public var source: IRCSource?
    public var command: IRCCommand
    public var parameters: [String]

    public init(
        tags: IRCTags = IRCTags(),
        source: IRCSource? = nil,
        command: IRCCommand,
        parameters: [String] = []
    ) {
        self.tags = tags
        self.source = source
        self.command = command
        self.parameters = parameters
    }

    public init(
        tags: IRCTags = IRCTags(),
        source: IRCSource? = nil,
        verb: String,
        parameters: [String] = []
    ) {
        self.init(tags: tags, source: source, command: .verb(verb), parameters: parameters)
    }

    // MARK: - Parsing

    /// Parses one line, which must already have had its `CRLF` removed.
    ///
    /// Returns `nil` only when there is no command at all.
    public init?(line: String) {
        var rest = Substring(line)

        func dropLeadingSpaces() {
            while rest.first == " " { rest = rest.dropFirst() }
        }

        /// Consumes up to the next space and returns it, leaving `rest` past the space.
        func takeToken() -> Substring? {
            dropLeadingSpaces()
            guard !rest.isEmpty else { return nil }
            if let space = rest.firstIndex(of: " ") {
                let token = rest[rest.startIndex..<space]
                rest = rest[rest.index(after: space)...]
                return token
            }
            let token = rest
            rest = rest[rest.endIndex...]
            return token
        }

        var tags = IRCTags()
        dropLeadingSpaces()
        if rest.first == "@", let section = takeToken() {
            tags = IRCTags.parse(section: section.dropFirst())
        }

        var source: IRCSource?
        dropLeadingSpaces()
        if rest.first == ":", let prefix = takeToken() {
            source = IRCSource(prefix: String(prefix.dropFirst()))
        }

        guard let commandToken = takeToken(), !commandToken.isEmpty else { return nil }

        var parameters: [String] = []
        while true {
            dropLeadingSpaces()
            guard !rest.isEmpty else { break }
            if rest.first == ":" {
                // Trailing parameter: everything left, spaces and all, colon dropped.
                parameters.append(String(rest.dropFirst()))
                break
            }
            guard let token = takeToken() else { break }
            parameters.append(String(token))
        }

        self.init(
            tags: tags,
            source: source,
            command: IRCCommand(token: String(commandToken)),
            parameters: parameters
        )
    }

    // MARK: - Serializing

    /// The line as it goes on the wire, without the trailing `CRLF`.
    public var wireForm: String {
        var line = ""
        if !tags.isEmpty {
            line += "@\(tags.wireForm) "
        }
        if let source {
            line += ":\(source.wireForm) "
        }
        line += command.wireForm
        for (index, parameter) in parameters.enumerated() {
            let isLast = index == parameters.count - 1
            if isLast, Self.mustBeTrailing(parameter) {
                line += " :\(parameter)"
            } else {
                line += " \(parameter)"
            }
        }
        return line
    }

    /// Whether a parameter can only be represented as the trailing parameter.
    ///
    /// Empty, containing a space, or beginning with `:` — each would otherwise be
    /// misread when parsed back.
    static func mustBeTrailing(_ parameter: String) -> Bool {
        parameter.isEmpty || parameter.contains(" ") || parameter.hasPrefix(":")
    }

    /// Byte length of ``wireForm`` plus `CRLF`, which is what the limits apply to.
    public var wireByteCount: Int {
        wireForm.utf8.count + 2
    }

    /// Whether this message fits inside the protocol limits.
    ///
    /// Tags and the rest of the message are budgeted separately, as IRCv3 specifies.
    public var fitsProtocolLimits: Bool {
        let tagBytes = tags.isEmpty ? 0 : tags.wireForm.utf8.count + 2  // '@' and the space
        var withoutTags = self
        withoutTags.tags = IRCTags()
        return tagBytes <= IRCProtocolLimits.maximumTagSectionBytes
            && withoutTags.wireByteCount <= IRCProtocolLimits.maximumMessageBytes
    }
}
