import Foundation

/// Appends wire traffic to a file, for `/debug <file>`.
///
/// **Everything written here has already been redacted**, because it comes from
/// ``TraceBuffer``, which redacts on insert. That is the property that makes the file
/// safe to attach to a bug report, and it is a property of where the events come from
/// rather than of anything this type does — there is no unredacted path to write.
///
/// Opened for append, never truncating: a debug log you asked for twice in one session
/// is one file with both halves in it, not the second half only.
public final class TraceFileWriter {
    /// Where the file actually landed, absolute. Reported back to the user, because a
    /// relative path in a command line and a file on disk should never be a mystery.
    public let url: URL

    private let handle: FileHandle

    /// - Parameter path: A user-typed path. `~` expands; a relative path resolves against
    ///   the home directory, which is the one location a user typing `debug.log` into a
    ///   chat window can be assumed to mean.
    public init(path: String) throws {
        self.url = Self.resolve(path)
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Writes one already-redacted line, with the same `>>`/`<<` markers the canvas uses.
    public func write(_ event: TraceEvent) {
        write(line: "\(Self.marker(for: event.direction)) \(event.line)")
    }

    /// Writes a line of our own — the banner that says what this file is.
    public func write(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Said out loud rather than swallowed, but without the payload: a failing
            // debug log must not become a second way to leak one.
            Log.ui.error("debug log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func close() {
        try? handle.close()
    }

    /// The same markers `DiagnosticsReport` and the raw-traffic toggle use, so a file, a
    /// clipboard export and the window all read the same way.
    private static func marker(for direction: TraceEvent.Direction) -> String {
        switch direction {
        case .outbound: ">>"
        case .inbound: "<<"
        }
    }

    private static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return URL(
                fileURLWithPath: expanded,
                relativeTo: FileManager.default.homeDirectoryForCurrentUser
            )
            .standardizedFileURL
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
