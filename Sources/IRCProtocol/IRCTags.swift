/// One IRCv3 message tag.
public struct IRCTag: Sendable, Hashable {
    public let key: String

    /// `nil` for a valueless tag (`@a`), `""` for an explicitly empty one (`@a=`).
    ///
    /// IRCv3 treats the two as equivalent, and so does ``IRCTags/value(for:)``. The
    /// distinction is kept in the model anyway so a captured line can be described
    /// exactly as it arrived — a trace that silently rewrites the wire is worth less.
    public let value: String?

    public init(key: String, value: String? = nil) {
        self.key = key
        self.value = value
    }
}

/// The tag section of a message, in wire order.
///
/// Ordered rather than a dictionary because order is part of what arrived, and
/// duplicate keys are legal on the wire even though only the last one counts.
public struct IRCTags: Sendable, Hashable, ExpressibleByArrayLiteral {
    public private(set) var tags: [IRCTag]

    public init(_ tags: [IRCTag] = []) {
        self.tags = tags
    }

    public init(arrayLiteral elements: IRCTag...) {
        self.tags = elements
    }

    public var isEmpty: Bool { tags.isEmpty }
    public var count: Int { tags.count }

    /// The effective value for `key`, or `nil` if the tag is absent.
    ///
    /// A valueless tag reports `""`, matching IRCv3's rule that `@a` and `@a=` mean the
    /// same thing. Later duplicates win, as they do on the wire.
    public func value(for key: String) -> String? {
        tags.last { $0.key == key }.map { $0.value ?? "" }
    }

    public func contains(_ key: String) -> Bool {
        tags.contains { $0.key == key }
    }

    /// Last-wins flattening, with valueless tags reported as `""`.
    public var dictionary: [String: String] {
        var result: [String: String] = [:]
        for tag in tags {
            result[tag.key] = tag.value ?? ""
        }
        return result
    }

    public mutating func append(_ tag: IRCTag) {
        tags.append(tag)
    }

    // MARK: - Escaping

    /// Unescapes a tag value per IRCv3.
    ///
    /// `\:` → `;`, `\s` → space, `\\` → `\`, `\r` → CR, `\n` → LF. An unrecognised
    /// escape drops the backslash and keeps the character; a lone trailing backslash
    /// is dropped entirely.
    /// Both directions iterate `unicodeScalars`, not `Characters`.
    ///
    /// Swift treats `CR LF` as a *single* grapheme cluster, so a `for character in`
    /// loop sees `"\r\n"` as one `Character` that matches neither `"\r"` nor `"\n"` —
    /// and a tag value containing a bare CRLF silently survives escaping intact,
    /// producing a line that terminates early on the wire. The corpus catches exactly
    /// this case.
    public static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = String.UnicodeScalarView()
        var iterator = value.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            guard let escaped = iterator.next() else { break }  // lone trailing backslash
            switch escaped {
            case ":": result.append(";")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            case "r": result.append("\r")
            case "n": result.append("\n")
            default: result.append(escaped)
            }
        }
        return String(result)
    }

    /// Escapes a tag value for the wire.
    public static func escape(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case ";": result.append(contentsOf: "\\:".unicodeScalars)
            case " ": result.append(contentsOf: "\\s".unicodeScalars)
            case "\\": result.append(contentsOf: "\\\\".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: - Wire form

    /// Parses the tag section, which the caller supplies without its leading `@`.
    public static func parse(section: Substring) -> IRCTags {
        var tags: [IRCTag] = []
        for field in section.split(separator: ";", omittingEmptySubsequences: true) {
            if let equals = field.firstIndex(of: "=") {
                let key = String(field[field.startIndex..<equals])
                let raw = field[field.index(after: equals)...]
                tags.append(IRCTag(key: key, value: unescape(String(raw))))
            } else {
                tags.append(IRCTag(key: String(field), value: nil))
            }
        }
        return IRCTags(tags)
    }

    /// Serialized tag section, without the leading `@`.
    ///
    /// An empty value is written in the valueless form (`@a` rather than `@a=`). The
    /// two are equivalent per IRCv3, and the shorter form is the one the upstream
    /// parser-tests corpus accepts in every case that admits both.
    public var wireForm: String {
        tags.map { tag in
            guard let value = tag.value, !value.isEmpty else { return tag.key }
            return "\(tag.key)=\(Self.escape(value))"
        }
        .joined(separator: ";")
    }
}
