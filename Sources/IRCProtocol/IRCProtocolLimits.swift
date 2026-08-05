/// Wire size limits.
public enum IRCProtocolLimits {
    /// Maximum bytes in the tag section, including the leading `@` and the space that
    /// separates it from the rest of the message. From the IRCv3 message-tags spec.
    public static let maximumTagSectionBytes = 8191

    /// Maximum bytes in the message excluding tags, including the trailing `CRLF`.
    /// From RFC 1459.
    public static let maximumMessageBytes = 512
}

extension String {
    /// Truncates to at most `maxUTF8Bytes`, never splitting a character.
    ///
    /// Explicit rather than implicit: something has to give when a message is too long,
    /// and dropping whole characters off the end is the least surprising option.
    /// Cutting mid-scalar would produce invalid UTF-8 and cutting mid-grapheme would
    /// mangle emoji and combining marks.
    public func truncated(to maxUTF8Bytes: Int) -> String {
        guard maxUTF8Bytes >= 0 else { return "" }
        guard utf8.count > maxUTF8Bytes else { return self }
        var result = ""
        var used = 0
        for character in self {
            let width = String(character).utf8.count
            if used + width > maxUTF8Bytes { break }
            result.append(character)
            used += width
        }
        return result
    }
}
