/// A `FAIL`, `WARN` or `NOTE` — IRCv3's typed answer to a command.
///
/// The point of the `standard-replies` capability is that a client can tell the three
/// apart without a table of numerics per network: `FAIL` means the command did not
/// happen, `WARN` means it happened with a caveat, `NOTE` is commentary. Rendering all
/// three as the same grey numeric would throw away the only thing they add.
public struct StandardReply: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case fail = "FAIL"
        case warn = "WARN"
        case note = "NOTE"
    }

    public let severity: Severity
    /// The command being replied to, or `*` when the server names none.
    public let command: String
    /// A machine-readable code, e.g. `ACCOUNT_REQUIRED_TO_CONNECT`.
    public let code: String
    /// Whatever the server put between the code and the description.
    public let context: [String]
    /// The human-readable description, which is what the user reads.
    public let text: String

    public init(
        severity: Severity,
        command: String,
        code: String,
        context: [String] = [],
        text: String
    ) {
        self.severity = severity
        self.command = command
        self.code = code
        self.context = context
        self.text = text
    }

    /// `FAIL JOIN CHANNEL_FULL #chan :Channel is full`.
    ///
    /// The description is the trailing parameter and the code is the one before whatever
    /// context the server chose to include, so both ends are fixed and the middle is
    /// whatever is left.
    init?(message parameters: [String], severity: Severity) {
        guard parameters.count >= 3 else { return nil }
        self.severity = severity
        self.command = parameters[0]
        self.code = parameters[1]
        self.context = Array(parameters.dropFirst(2).dropLast())
        self.text = parameters[parameters.count - 1]
    }

    /// The line a user reads: the description, with the code kept only when it adds
    /// something the description does not already say.
    public var summary: String {
        text.isEmpty ? "\(command): \(code)" : text
    }
}
