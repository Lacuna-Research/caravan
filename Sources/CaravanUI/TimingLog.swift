import AppKit
import Foundation

/// Timestamps for "why did that take so long", written where somebody can read them.
///
/// **Switched on by a file, not by an environment variable.** The app is launched by
/// double-clicking it, and a double-clicked app never sees a shell's environment — an
/// `EnvVar=1` diagnostic is one you can only use from a terminal, which is not where the
/// problem is being reported from. Creating `timing.on` in the cache directory turns it on;
/// deleting it turns it off. The variable is honoured too, because scripts have one.
///
/// **Off by default and free when off**: one `fileExists` at launch, and every `note` after
/// that is an early return on a `Bool`.
///
/// Nothing here records what anybody typed or said. It records *when things happened* —
/// window shown, mouse down, selection changed — because the reports it exists to settle
/// are about lag rather than content.
public enum TimingLog {
    /// `~/.cache/caravan/timing.on` — create it to record, delete it to stop.
    public static var switchURL: URL { AppDirectories.cache.appending(path: "timing.on") }

    /// `~/.cache/caravan/timing.log` — where the lines go.
    public static var logURL: URL { AppDirectories.cache.appending(path: "timing.log") }

    public static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CARAVAN_TIMING_LOG"] != nil { return true }
        return FileManager.default.fileExists(atPath: switchURL.path)
    }()

    /// Wall clock for the reader, and monotonic for the arithmetic — a log meant for
    /// measuring gaps should not be one where somebody has to subtract clock times by hand,
    /// and wall clock alone can step sideways mid-measurement.
    private static let started = ContinuousClock.now
    private static let lock = NSLock()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Records one moment. Called from the main thread in practice; locked anyway, because a
    /// diagnostic that corrupts its own file under concurrency is worse than none.
    public static func note(_ what: String) {
        guard isEnabled else { return }
        let elapsed = Double(ContinuousClock.now.duration(to: started).components.attoseconds)
        let seconds = -elapsed / 1e18
        let line = String(
            format: "%@  %8.3f  %@\n",
            stamp.string(from: Date()),
            seconds,
            what
        )
        lock.lock()
        defer { lock.unlock() }
        write(line)
    }

    /// Runs `body`, records how long it took, and hands back what it returned.
    public static func measure<T>(_ what: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = ContinuousClock.now
        let result = body()
        let taken = start.duration(to: ContinuousClock.now)
        note(
            "\(what) took \(taken.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))"
        )
        return result
    }

    /// Records every mouse-down the app receives, once.
    ///
    /// **A local monitor, which observes rather than intercepts.** It returns the event
    /// untouched, so nothing about clicking changes when this is on — a diagnostic that
    /// altered the thing being diagnosed would be worse than no diagnostic. It answers the
    /// question the report actually poses: did the click reach the app at all, and when?
    @MainActor
    public static func watchMouseDowns() {
        guard isEnabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            note("mouse down in \(event.window?.title ?? "no window")")
            return event
        }
    }

    @MainActor private static var monitor: Any?

    private static func write(_ line: String) {
        let directory = AppDirectories.cache
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
