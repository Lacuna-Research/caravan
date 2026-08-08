import Diagnostics
import Foundation

/// The plain-text settings file, at `$XDG_CONFIG_HOME/caravan/caravan.conf`.
///
/// **Its path and its format are public API.** A user is expected to open this in an
/// editor, and the app is expected not to punish them for it:
///
/// - **Comments and unknown keys survive a write.** Only the line belonging to the key
///   being set is rewritten; everything else is passed through verbatim. A settings form
///   that silently ate a user's comments would make the file editable in name only.
/// - **A key that is absent takes its default**, rather than being written out eagerly.
///   So the file stays as short as what the user has actually changed, and a default that
///   improves in a later version improves for everyone who never touched it.
/// - **Nothing here is a credential.** Passwords live in the Keychain (stage 2); until
///   they do, they are re-typed per connection and written nowhere.
///
/// Format: `key = value`, one per line. `#` and `;` start a comment. Whitespace around
/// the key and the value is not significant, so a value cannot begin or end with a
/// space — no setting needs one, and the alternative is a quoting scheme nobody asked
/// for.
@MainActor
public final class ConfigFile {
    /// The one the app uses. Tests build their own against a temporary directory.
    public static let shared = ConfigFile()

    public let url: URL

    /// The file as lines of text, in order, comments and all.
    private var lines: [String]

    /// `$XDG_CONFIG_HOME/caravan`, defaulting to `~/.config/caravan`.
    ///
    /// The XDG rule, not `~/Library/Application Support`: config files here are meant to
    /// be edited and version-controlled by the people who use them, and hiding them
    /// inside a Library folder macOS actively discourages browsing is the opposite of
    /// that. `BUILD-LOG.md` carries the reasoning.
    public static var directory: URL { AppDirectories.config }

    public init(url: URL = ConfigFile.directory.appending(path: "caravan.conf")) {
        self.url = url
        self.lines = Self.read(url)
    }

    // MARK: - Reading

    public func string(_ key: String) -> String? {
        guard let index = index(of: key) else { return nil }
        return Self.parse(lines[index])?.value
    }

    public func bool(_ key: String) -> Bool? {
        switch string(key)?.lowercased() {
        case "true", "yes", "on", "1": true
        case "false", "no", "off", "0": false
        default: nil
        }
    }

    public func int(_ key: String) -> Int? {
        string(key).flatMap(Int.init)
    }

    public func double(_ key: String) -> Double? {
        string(key).flatMap(Double.init)
    }

    // MARK: - Writing

    /// Sets a key, or removes its line entirely when `value` is `nil`.
    ///
    /// Removing rather than writing an empty value is what makes "reset to default" a
    /// thing the file can express: an absent key takes the current default, and an empty
    /// one is a deliberate empty string — which `timestamp-format` uses to mean "no
    /// timestamps at all".
    public func set(_ value: String?, forKey key: String) {
        let existing = index(of: key)
        switch (value, existing) {
        case (let value?, let index?):
            guard Self.parse(lines[index])?.value != value else { return }
            lines[index] = "\(key) = \(value)"
        case (let value?, nil):
            lines.append("\(key) = \(value)")
        case (nil, let index?):
            lines.remove(at: index)
        case (nil, nil):
            return
        }
        write()
    }

    /// Every key currently in the file that begins with `prefix`.
    ///
    /// For settings that are a *set* rather than a scalar — the colour overrides are one
    /// key per overridden index, and writing the new set means knowing which old keys to
    /// remove. Reading the file back rather than remembering what was written keeps a
    /// hand-added `chat.colour.7` from being invisible to the app that owns it.
    public func keys(withPrefix prefix: String) -> [String] {
        lines.compactMap { Self.parse($0)?.key }.filter { $0.hasPrefix(prefix) }
    }

    public func set(_ value: Bool, forKey key: String) {
        set(value ? "true" : "false", forKey: key)
    }

    public func set(_ value: Int, forKey key: String) {
        set(String(value), forKey: key)
    }

    /// `%g` so a font size of 13 is written `13` rather than `13.0`. The file is read by
    /// people, and `13.0` reads as a precision nobody chose.
    public func set(_ value: Double, forKey key: String) {
        set(String(format: "%g", value), forKey: key)
    }

    // MARK: - The file itself

    private func index(of key: String) -> Int? {
        lines.firstIndex { Self.parse($0)?.key == key }
    }

    private static func parse(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
            let separator = trimmed.firstIndex(of: "=")
        else { return nil }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func read(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        // A trailing newline splits into a final empty component. Dropping it here and
        // adding one back on write keeps the file from growing a blank line per save.
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private func write() {
        var contents = lines
        if contents.isEmpty || Self.parse(contents[0]) != nil {
            contents.insert(contentsOf: Self.header, at: 0)
        }
        let text = contents.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
            lines = contents
        } catch {
            // Settings that fail to persist are worth saying out loud, and worth saying
            // without the values: this file holds a nickname, which is personal data even
            // though it is not a credential.
            Log.ui.error("could not write \(self.url.lastPathComponent, privacy: .public)")
        }
    }

    /// Written once, above a file that has no comment of its own yet. A user opening this
    /// for the first time should not have to guess what it is or where the rest went.
    private static let header = [
        "# Caravan configuration. Plain text, and meant to be edited.",
        "# One `key = value` per line; `#` starts a comment. A key that is not here",
        "# takes its default. Passwords are never stored in this file.",
        "",
    ]
}
