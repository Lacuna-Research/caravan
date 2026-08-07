/// A CTCP request or reply: a keyword and its argument, wrapped in `\u{01}`.
///
/// CTCP is not a command of its own on the wire — it is an ordinary `PRIVMSG` or
/// `NOTICE` whose text begins with `\u{01}`. `PRIVMSG` carries a *request*, `NOTICE`
/// carries the *reply*, and that asymmetry is the only thing stopping two clients
/// answering each other forever.
///
/// Here rather than in `IRCSession` because it is a parser and a table, and the module
/// layout puts those in the pure module that CI builds on Linux — the same reasoning
/// that put the colour tables in `IRCFormat`. A wrapper exercised only through a text
/// view is one nobody exercises.
public struct CTCPMessage: Sendable, Hashable {
    /// The wrapper. `\u{01}`, and nothing else has ever meant it.
    public static let delimiter: Character = "\u{01}"

    /// The keyword as it was received — `VERSION`, `PING`, `ACTION`.
    public let command: String

    /// Everything after the first space, or `nil` when there was none.
    ///
    /// `nil` and `""` are deliberately different: `\u{01}PING\u{01}` and
    /// `\u{01}PING \u{01}` are different lines, and a `PING` reply has to echo back what
    /// it was given rather than a normalised version of it.
    public let argument: String?

    public init(command: String, argument: String? = nil) {
        self.command = command
        self.argument = argument
    }

    /// Parses the text of a `PRIVMSG` or `NOTICE`, or returns `nil` for one that is not
    /// CTCP at all.
    ///
    /// **Only a leading delimiter counts.** A `\u{01}` in the middle of a sentence is a
    /// stray control character in someone's paste, not a request, and treating it as one
    /// is how a client is talked into answering something it never meant to.
    ///
    /// A missing *closing* delimiter is tolerated, because that is what a message
    /// truncated at 512 bytes looks like and showing the request is better than showing
    /// the control characters. An empty keyword — a bare `\u{01}\u{01}` — is not a CTCP.
    public init?(text: String) {
        guard text.first == Self.delimiter else { return nil }
        var body = text.dropFirst()
        if body.last == Self.delimiter { body = body.dropLast() }

        guard let space = body.firstIndex(of: " ") else {
            guard !body.isEmpty else { return nil }
            self.init(command: String(body))
            return
        }
        let command = String(body[body.startIndex..<space])
        guard !command.isEmpty else { return nil }
        self.init(command: command, argument: String(body[body.index(after: space)...]))
    }

    /// The keyword folded for comparison. CTCP keywords are ASCII and case-insensitive,
    /// and a client that only answered upper-case `VERSION` would look broken to whoever
    /// typed the other one.
    public var keyword: String { command.uppercased() }

    /// Whether this is the one CTCP that is a message rather than a request.
    ///
    /// `ACTION` is `/me`. It is never answered and never rendered as a request — it is a
    /// line of conversation that happens to use the wrapper.
    public var isAction: Bool { keyword == "ACTION" }

    /// The text to put in a `PRIVMSG` or `NOTICE` parameter.
    public var wireForm: String {
        let body = argument.map { "\(command) \($0)" } ?? command
        return "\(Self.delimiter)\(body)\(Self.delimiter)"
    }

    /// How the request reads in a buffer: `VERSION`, or `PING 1234567`.
    public var summary: String {
        argument.map { $0.isEmpty ? command : "\(command) \($0)" } ?? command
    }
}
