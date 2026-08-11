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

    public static let isEnabled: Bool = shouldEnable(
        environment: ProcessInfo.processInfo.environment,
        switchExists: FileManager.default.fileExists(atPath: switchURL.path)
    )

    /// The decision, separated from the world it asks about.
    ///
    /// **Because the obvious test is a trap.** Asserting `isEnabled == false` reads the
    /// developer's own home directory, so the suite passed until somebody switched the log
    /// on to use it — and then failed on a machine where nothing was wrong. A pure function
    /// can be asked all four questions without owning a filesystem.
    static func shouldEnable(environment: [String: String], switchExists: Bool) -> Bool {
        environment["CARAVAN_TIMING_LOG"] != nil || switchExists
    }

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
        // **Both components, which the first version got wrong.** `Duration.components` is
        // (seconds, attoseconds), and reading only the attoseconds gives the *fractional*
        // part — so a line twenty-nine seconds in was logged as 0.030, and the column that
        // exists to measure gaps could not measure anything past a second.
        let seconds = Self.seconds(of: started.duration(to: ContinuousClock.now).components)
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

    /// A `Duration` as a number of seconds.
    ///
    /// **Both components, which the first version got wrong.** `Duration.components` is
    /// (seconds, attoseconds), and reading only the attoseconds gives the *fractional* part
    /// — so a line twenty-nine seconds in was logged as 0.030, and the column that exists to
    /// measure gaps could not measure one longer than a second.
    static func seconds(of components: (seconds: Int64, attoseconds: Int64)) -> Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
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
    /// **Says so when it starts watching**, which is the difference between a useful log and
    /// an ambiguous one. If the file shows "watching mouse events" and then no mouse-downs
    /// while somebody is clicking, that is itself the finding — clicks are not reaching the
    /// app — rather than leaving a reader wondering whether the monitor was ever installed.
    /// It cannot be checked by automation: `System Events`' `click at` drives accessibility
    /// rather than posting a mouse event, so a scripted click produces no `NSEvent` at all.
    @MainActor
    public static func watchMouseDowns() {
        guard isEnabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            note("mouse down in \(event.window?.title ?? "no window")")
            return event
        }
        note("watching mouse events")
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
