/// Strips credentials out of a raw IRC line.
///
/// Applied on insert into ``TraceBuffer``, never on export. If credentials were only
/// stripped on the way out, the plaintext would still be resident in the buffer, in
/// any crash dump, and in whatever debug path someone adds later. Stripping once at
/// the boundary means the password exists nowhere but the socket write itself.
///
/// This is security-relevant code. It is also the code most likely to be *too*
/// aggressive: over-redaction destroys the debuggability the trace buffer exists for,
/// so matching is command-aware rather than a substring hunt for scary-looking words.
/// A channel message containing the word "identify" must survive untouched.
///
/// Deliberately does not depend on `IRCProtocol`. The tokenizer here is the minimum
/// needed to find a command and its parameters — it does not validate, unescape tags,
/// or build a message. Prompt 3 does parsing properly; this must keep working on
/// lines that parser would reject.
public enum Redactor {
    /// Replaces every redacted span.
    public static let placeholder = "<redacted>"

    /// SASL mechanism names and control tokens, which are not secrets. Everything else
    /// in an `AUTHENTICATE` parameter is a credential payload.
    private static let authenticateAllowlist: Set<String> = [
        "+", "*", "PLAIN", "EXTERNAL", "ANONYMOUS",
        "SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-512",
        "ECDSA-NIST256P-CHALLENGE",
    ]

    /// Services aliases that take a credential-bearing subcommand.
    private static let serviceTargets: Set<String> = ["NICKSERV", "NS"]

    /// NickServ subcommands whose arguments contain a secret.
    ///
    /// Every argument after the keyword is redacted, not just the last. `SETPASS`
    /// carries both a key and a new password, and for the others the account name is
    /// recoverable from context — a leaked password is not.
    private static let serviceSecretCommands: Set<String> = [
        "IDENTIFY", "GHOST", "REGAIN", "RELEASE", "SETPASS",
    ]

    /// Returns `line` with any credential replaced by ``placeholder``.
    ///
    /// Tags and the source prefix are preserved byte for byte; only parameter spans
    /// are ever rewritten.
    public static func redact(_ line: String) -> String {
        var scanner = Scanner(line)
        scanner.skipTags()
        scanner.skipPrefix()

        guard let commandRange = scanner.takeToken() else { return line }
        let command = line[commandRange].uppercased()

        var redaction: Range<String.Index>?

        switch command {
        case "PASS":
            redaction = scanner.takeParameter()?.content

        case "AUTHENTICATE":
            if let parameter = scanner.takeParameter() {
                let value = String(line[parameter.content]).uppercased()
                if !authenticateAllowlist.contains(value) {
                    redaction = parameter.content
                }
            }

        case "OPER":
            _ = scanner.takeParameter()  // Operator name is not a secret; keep it.
            redaction = scanner.takeParameter()?.content

        case "PRIVMSG", "NOTICE":
            guard let target = scanner.takeParameter(),
                serviceTargets.contains(line[target.content].uppercased()),
                let body = scanner.takeParameter()
            else { break }
            redaction = argumentsAfterSecretKeyword(in: line, within: body.content)

        case "NS", "NICKSERV":
            // Server-side alias: the subcommand is the first parameter.
            if let body = scanner.remainder() {
                redaction = argumentsAfterSecretKeyword(in: line, within: body)
            }

        default:
            break
        }

        guard let redaction, !redaction.isEmpty else { return line }
        return line.replacingCharacters(in: redaction, with: placeholder)
    }

    /// Given the body of a services message, returns the span covering every argument
    /// after a secret-bearing keyword, or `nil` if the first word is not one.
    private static func argumentsAfterSecretKeyword(
        in line: String,
        within body: Range<String.Index>
    ) -> Range<String.Index>? {
        var scanner = Scanner(line, from: body.lowerBound, to: body.upperBound)
        guard let keywordRange = scanner.takeToken(),
            serviceSecretCommands.contains(line[keywordRange].uppercased())
        else { return nil }
        guard let argumentsStart = scanner.nextNonSpace() else { return nil }
        return argumentsStart..<body.upperBound
    }
}

/// Minimal forward scanner over a raw line. Not a parser — see the note on ``Redactor``.
private struct Scanner {
    private let line: String
    private var cursor: String.Index
    private let end: String.Index

    init(_ line: String) {
        self.line = line
        self.cursor = line.startIndex
        self.end = line.endIndex
    }

    init(_ line: String, from start: String.Index, to end: String.Index) {
        self.line = line
        self.cursor = start
        self.end = end
    }

    private mutating func skipSpaces() {
        while cursor < end, line[cursor] == " " {
            cursor = line.index(after: cursor)
        }
    }

    /// Skips an IRCv3 tag section (`@a=b;c`) if present. Contents are never inspected —
    /// tags are preserved verbatim.
    mutating func skipTags() {
        skipSpaces()
        guard cursor < end, line[cursor] == "@" else { return }
        _ = takeToken()
    }

    /// Skips a source prefix (`:nick!user@host`) if present.
    ///
    /// Skipping matters for correctness, not just tidiness: a user whose nick is `pass`
    /// would otherwise look like a `PASS` command to a naive scan.
    mutating func skipPrefix() {
        skipSpaces()
        guard cursor < end, line[cursor] == ":" else { return }
        _ = takeToken()
    }

    /// Index of the next non-space character, or `nil` at end of input.
    mutating func nextNonSpace() -> String.Index? {
        skipSpaces()
        return cursor < end ? cursor : nil
    }

    /// Consumes a space-delimited token.
    mutating func takeToken() -> Range<String.Index>? {
        skipSpaces()
        guard cursor < end else { return nil }
        let start = cursor
        while cursor < end, line[cursor] != " " {
            cursor = line.index(after: cursor)
        }
        return start..<cursor
    }

    /// Consumes one parameter. A leading `:` marks the trailing parameter, which runs
    /// to end of input; the returned range excludes the colon so redaction preserves it.
    mutating func takeParameter() -> (content: Range<String.Index>, isTrailing: Bool)? {
        skipSpaces()
        guard cursor < end else { return nil }
        if line[cursor] == ":" {
            let start = line.index(after: cursor)
            cursor = end
            return (start..<end, true)
        }
        guard let token = takeToken() else { return nil }
        return (token, false)
    }

    /// Everything left, with a leading `:` stripped if present.
    mutating func remainder() -> Range<String.Index>? {
        skipSpaces()
        guard cursor < end else { return nil }
        if line[cursor] == ":" {
            cursor = line.index(after: cursor)
        }
        let start = cursor
        cursor = end
        return start < end ? start..<end : nil
    }
}
