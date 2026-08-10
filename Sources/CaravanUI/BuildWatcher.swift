import AppKit
import Foundation
import Observation

/// What is on disk where this process was launched from.
///
/// Three fields rather than a modification date alone: `make install` swaps the whole
/// bundle, so the inode changes even when a rebuild happens to land on the same second, and
/// the size catches the case where a filesystem hands back a recycled inode.
public struct BuildIdentity: Equatable, Sendable {
    public let size: Int
    public let modified: Date
    public let inode: UInt64

    /// Reads the identity of a file, or `nil` when it is not there.
    ///
    /// **`nil` is "ask again later", never "it changed".** The install moves the old bundle
    /// aside and then moves the new one in, so a poll landing between those two sees no file
    /// at all — and a watcher that treated an absent file as a new build would announce one
    /// every time, a fraction of a second before it was true.
    public static func of(_ url: URL) -> BuildIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int,
            let modified = attributes[.modificationDate] as? Date,
            let inode = attributes[.systemFileNumber] as? UInt64
        else { return nil }
        return BuildIdentity(size: size, modified: modified, inode: inode)
    }
}

/// Notices when the app on disk stops being the app that is running.
///
/// `make install` replaces `/Applications/Caravan.app` underneath a running copy, which
/// keeps executing the code it started with. That is a confusing way to discover a fix did
/// not land — the app looks current and is not — so it says so instead.
///
/// **Polled on a deadline, not watched with a `DispatchSource`.** The bundle is *replaced*
/// rather than written to, so a file descriptor held on the old executable is a descriptor
/// on a file that has been moved aside and deleted; re-arming it means re-opening the path
/// anyway. A loop that sleeps to a deadline is the shape this codebase already uses for
/// `IRCSession.idleMonitor()` and `ChannelDirectory`, it costs one `stat` a minute, and it
/// cannot get stuck watching a path nothing will ever touch again.
@MainActor
@Observable
public final class BuildWatcher {
    /// Whether the build on disk differs from the one running, and has not been waved away.
    public var isShowingNotice: Bool { newBuild != nil && newBuild != dismissed }

    /// The identity of the build on disk, once it differs from the running one.
    public private(set) var newBuild: BuildIdentity?

    /// What the user pressed "Later" on. Kept as an *identity* rather than a flag so a
    /// second install after a dismissal says so again — otherwise waving one away would
    /// silence every future build for the life of the process.
    @ObservationIgnored private var dismissed: BuildIdentity?

    @ObservationIgnored private let executable: URL
    @ObservationIgnored private let probe: @MainActor (URL) -> BuildIdentity?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let launched: BuildIdentity?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - executable: what to watch. Defaults to this process's own binary.
    ///   - probe: how to read an identity, injectable so a test does not need to install
    ///     anything over itself.
    public init(
        executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/nonexistent"),
        interval: Duration = .seconds(60),
        probe: @escaping @MainActor (URL) -> BuildIdentity? = { BuildIdentity.of($0) }
    ) {
        self.executable = executable
        self.interval = interval
        self.probe = probe
        self.launched = probe(executable)
    }

    deinit { task?.cancel() }

    /// Begins watching. Called by the app; never by a test, which drives ``check()``.
    public func start() {
        guard task == nil, launched != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.check()
            }
        }
    }

    /// One look at the disk. Public so the app can also ask on becoming active, which is
    /// when somebody who has just run `make install` is most likely to be looking.
    public func check() {
        guard let launched, let current = probe(executable) else { return }
        guard current != launched else {
            // Rolled back to the running build — an install of the same code, or the old
            // bundle restored. There is nothing to restart into.
            newBuild = nil
            return
        }
        if current != newBuild { dismissed = nil }
        newBuild = current
    }

    /// "Later". Hides this build's notice; a *different* build says so again.
    public func dismiss() {
        dismissed = newBuild
    }

    /// Quits and comes back.
    ///
    /// **The replacement is launched after this process has gone, not before.** Two copies
    /// running at once share one `$XDG_CONFIG_HOME`, and two processes writing one
    /// `caravan.conf` is a way to lose settings that is much harder to explain than the
    /// second of delay this costs.
    ///
    /// Connections are dropped rather than parted with a `QUIT`, because that is what
    /// quitting already does — see `PLAN.md`'s **Still open**.
    public func restart(bundle: URL = Bundle.main.bundleURL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"\(bundle.path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}
