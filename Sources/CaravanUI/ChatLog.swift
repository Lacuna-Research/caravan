import Diagnostics
import Foundation

/// Plain-text chat logs, one file per buffer, under `$XDG_DATA_HOME/caravan/logs`.
///
/// **mIRC's log, with one deliberate departure.** The sentences are mIRC's, straight out of
/// ``LineFormatTable/mIRC``, the codes are stripped and the file is plain text you can
/// `grep`. What differs is the stamp: mIRC writes `[HH:mm:ss]` and leaves the date to a
/// `Session Start:` banner at the top of the file. That is unusable here, because
/// reconciling a logged line against a bouncer's `chathistory` replay means comparing a
/// *moment*, and a date recoverable only by scanning backwards for the nearest banner is
/// not a moment a line carries. So every line carries `[yyyy-MM-dd HH:mm:ss]` and is
/// self-describing, which is also what makes ``tail(_:network:buffer:)`` a seek to the end
/// of the file rather than a parse of the whole of it.
///
/// **What is written here is never what is on screen.** The buffer renders with the user's
/// `chat.timestamp-format`, their palette and their density; the log renders canonically.
/// A log whose shape changed when somebody tried out a timestamp format would be a log
/// nothing could ever read back.
///
/// **No raw wire traffic, ever.** That is `/debug` and ``TraceFileWriter``, which redacts on
/// insert; a chat log has no redaction pass and must never become a second route for a
/// `PASS` to reach the disk.
@MainActor
public final class ChatLog {
    /// The root every network's directory sits under.
    public let directory: URL

    /// Open append handles, by path. A client with thirty buffers holds thirty descriptors,
    /// which is nothing; closing and reopening per line is a `open`/`close` pair per message
    /// and is the thing worth avoiding.
    private var handles: [String: FileHandle] = [:]

    /// Paths this session has already failed to open. Without it a directory that cannot be
    /// created produces one log line per chat line, which is a worse failure than the one
    /// being reported.
    private var failed: Set<String> = []

    public static var defaultDirectory: URL { AppDirectories.data.appending(path: "logs") }

    public init(directory: URL = ChatLog.defaultDirectory) {
        self.directory = directory
    }

    deinit {
        for handle in handles.values { try? handle.close() }
    }

    // MARK: - Paths

    public func networkDirectory(_ network: String) -> URL {
        directory.appending(path: Self.escape(network))
    }

    /// Where one buffer's log lives.
    public func url(network: String, buffer: String) -> URL {
        networkDirectory(network).appending(path: "\(Self.escape(buffer)).log")
    }

    /// A buffer name as a path component.
    ///
    /// **A channel name is not a filename and a nick is not either.** `/` is a path
    /// separator, `:` is one to everything that still speaks HFS, and a name that folds to
    /// `.` or `..` names a directory rather than a file. Nicks may legitimately contain
    /// `[ ] \ { } | ^`, all of which are fine, so the escape is deliberately narrow —
    /// percent-encoding only what is dangerous keeps `#swift.log` readable, which matters
    /// for a directory a user is invited to open in Finder.
    ///
    /// `%` itself is escaped first, without which the mapping would not be reversible and
    /// `#a%2Fb` and `#a/b` would be one file.
    static func escape(_ name: String) -> String {
        var escaped = ""
        for character in name.unicodeScalars {
            if character == "%" || character == "/" || character == ":" || character.value < 0x20 {
                escaped += String(format: "%%%02X", character.value)
            } else {
                escaped.unicodeScalars.append(character)
            }
        }
        // `.` and `..` are directories, and a leading dot hides the file from the Finder
        // window this feature invites people to open.
        if escaped == "." || escaped == ".." || escaped.hasPrefix(".") {
            escaped = "%2E" + String(escaped.dropFirst())
        }
        return escaped.isEmpty ? "%00" : escaped
    }

    /// The inverse, for showing a scanned directory back to the user.
    static func unescape(_ name: String) -> String {
        name.removingPercentEncoding ?? name
    }

    // MARK: - Writing

    /// Appends one already-rendered plain line. The newline is added here.
    public func write(_ line: String, network: String, buffer: String) {
        let url = url(network: network, buffer: buffer)
        guard let handle = handle(for: url) else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Named without its payload: a failing chat log must not become a second way to
            // put what somebody said into the system log.
            Log.ui.error("chat log write failed: \(error.localizedDescription, privacy: .public)")
            try? handle.close()
            handles[url.path] = nil
            failed.insert(url.path)
        }
    }

    private func handle(for url: URL) -> FileHandle? {
        if let existing = handles[url.path] { return existing }
        guard !failed.contains(url.path) else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            handles[url.path] = handle
            return handle
        } catch {
            Log.ui.error(
                "could not open a chat log: \(error.localizedDescription, privacy: .public)"
            )
            failed.insert(url.path)
            return nil
        }
    }

    /// Closes every open handle. For a test that wants to read what it just wrote, and for
    /// an app on its way out.
    public func close() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }

    /// Flushes without closing, so a reader sees what a writer has just written.
    public func flush() {
        for handle in handles.values { try? handle.synchronize() }
    }

    // MARK: - Reading

    /// How much of the end of a file ``tail(_:network:buffer:)`` will look at.
    ///
    /// A bound rather than a whole-file read: a channel logged for a year is megabytes, and
    /// the fifty lines somebody wants back are in the last few kilobytes of it. Two hundred
    /// characters a line puts five thousand lines inside this window, which is far past any
    /// reload count the form offers.
    static let tailWindow = 1 << 20

    /// The last `count` lines of a buffer's log, oldest first.
    public func tail(_ count: Int, network: String, buffer: String) -> [String] {
        guard count > 0 else { return [] }
        flush()
        return Self.tail(count, of: url(network: network, buffer: buffer))
    }

    static func tail(_ count: Int, of url: URL) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let window = UInt64(tailWindow)
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd()
        else { return [] }

        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        // A window that did not start at the beginning of the file almost certainly began
        // mid-line, and half a line is not a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(count)
    }

    // MARK: - Browsing

    /// The networks that have logs, as they are named on disk.
    public func networks() -> [String] {
        Self.children(of: directory, directories: true).map(Self.unescape).sorted()
    }

    /// The buffers a network has logs for.
    public func buffers(in network: String) -> [String] {
        Self.children(of: networkDirectory(network), directories: false)
            .filter { $0.hasSuffix(".log") }
            .map { Self.unescape(String($0.dropLast(4))) }
            .sorted()
    }

    private static func children(of url: URL, directories: Bool) -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return (contents ?? []).compactMap { child in
            let isDirectory =
                (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory == directories else { return nil }
            return child.lastPathComponent
        }
    }

    // MARK: - The stamp

    /// How wide a stamp is: `yyyy-MM-dd HH:mm:ss`, nineteen characters, always.
    public nonisolated static let stampWidth = 19

    /// `2026-08-07 14:32:05`, in the local time zone.
    ///
    /// Local rather than UTC because the log is read by the person who was there, and a log
    /// whose times do not match the times they remember is a log they have to do arithmetic
    /// on. The consequence — that a stamp is ambiguous across a DST fold — costs at most a
    /// de-duplication miss in one hour a year.
    ///
    /// **Composed from `DateComponents` rather than by a `DateFormatter`.** This runs once
    /// per logged line and once per line read back, `DateFormatter` is not `Sendable` so it
    /// would need the lock-guarded cache the renderer keeps, and the format is fixed — none
    /// of the things a formatter is for apply.
    public nonisolated static func stamp(_ date: Date) -> String {
        let parts = calendar.dateComponents(stampFields, from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// The inverse. `nil` for anything that is not exactly a stamp — the log is a text file
    /// and somebody may well have typed in it.
    public nonisolated static func date(fromStamp stamp: String) -> Date? {
        let digits = Array(stamp.utf8)
        guard digits.count == stampWidth else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(digits[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard digits[4] == UInt8(ascii: "-"), digits[7] == UInt8(ascii: "-"),
            digits[10] == UInt8(ascii: " "), digits[13] == UInt8(ascii: ":"),
            digits[16] == UInt8(ascii: ":"),
            let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )
    }

    /// Gregorian explicitly, and not `Calendar.autoupdatingCurrent`: a user whose region
    /// selects the Japanese or Buddhist calendar would otherwise get a log stamped in the
    /// year 2569, and a file format is not the place to be locale-sensitive. The *time zone*
    /// does follow the system, which is the part the reader cares about.
    private nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    private nonisolated static let stampFields: Set<Calendar.Component> = [
        .year, .month, .day, .hour, .minute, .second,
    ]
}
