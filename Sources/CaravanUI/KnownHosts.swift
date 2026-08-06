import Diagnostics
import Foundation

/// Certificate fingerprints the user has accepted, per host. SSH's `known_hosts`, and
/// deliberately the same shape.
///
/// **Its path and its format are public API**, like `caravan.conf`: plain text, one
/// `host fingerprint` per line, `#` starts a comment. Deleting a line is how you forget a
/// decision, and that has to be doable in an editor rather than only by a button that
/// might not exist yet.
///
/// This is *not* a credential store — a fingerprint is public information — so it lives in
/// `$XDG_DATA_HOME/caravan` beside the rest of the app's data rather than in the Keychain.
@MainActor
public final class KnownHosts {
    public static let shared = KnownHosts()

    public let url: URL

    /// Fingerprint by lowercased host. One certificate per host: a server presenting two
    /// is a server whose second one is worth asking about.
    private var entries: [String: String] = [:]

    /// `$XDG_DATA_HOME/caravan`, defaulting to `~/.local/share/caravan`.
    public static var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let root =
            base.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".local/share")
        return root.appending(path: "caravan")
    }

    public init(url: URL = KnownHosts.directory.appending(path: "known_hosts")) {
        self.url = url
        self.entries = Self.read(url)
    }

    /// What we last accepted for this host, or `nil` if we have never been asked.
    public func fingerprint(for host: String) -> String? {
        entries[host.lowercased()]
    }

    /// Records a decision. Replacing an existing entry is how a rotated certificate is
    /// accepted, and it only happens after the user has been shown that it changed.
    public func remember(_ fingerprint: String, for host: String) {
        entries[host.lowercased()] = fingerprint
        write()
    }

    public func forget(_ host: String) {
        guard entries.removeValue(forKey: host.lowercased()) != nil else { return }
        write()
    }

    private static func read(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var entries: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = trimmed.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            entries[fields[0].lowercased()] = fields[1].trimmingCharacters(in: .whitespaces)
        }
        return entries
    }

    private func write() {
        let body = entries.keys.sorted().map { "\($0) \(entries[$0] ?? "")" }
        let text = (Self.header + body).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            // Worth saying out loud: a decision that did not persist means the user is
            // asked again next time, which reads as the client having forgotten.
            Log.ui.error("could not write \(self.url.lastPathComponent, privacy: .public)")
        }
    }

    private static let header = [
        "# TLS certificates Caravan has been told to trust, one host per line.",
        "# `host sha256-fingerprint`. Delete a line to be asked about that host again.",
        "",
    ]
}
