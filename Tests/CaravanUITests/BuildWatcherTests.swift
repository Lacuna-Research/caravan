import CaravanTestSupport
import Foundation
import Testing

@testable import CaravanUI

/// Noticing that the app on disk is no longer the app that is running.
@MainActor
@Suite("Noticing a new build")
struct BuildWatcherTests {
    private let url = URL(fileURLWithPath: "/Applications/Caravan.app/Contents/MacOS/Caravan")

    private func identity(_ inode: UInt64, size: Int = 1000) -> BuildIdentity {
        BuildIdentity(
            size: size,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            inode: inode
        )
    }

    /// A probe the test drives, so nothing has to be installed over the test runner.
    private final class Disk {
        var current: BuildIdentity?
        init(_ current: BuildIdentity?) { self.current = current }
    }

    private func watcher(_ disk: Disk) -> BuildWatcher {
        BuildWatcher(executable: url, interval: .seconds(3600)) { _ in disk.current }
    }

    @Test("the same build on disk says nothing")
    func unchanged() {
        let disk = Disk(identity(1))
        let watcher = watcher(disk)
        watcher.check()
        #expect(!watcher.isShowingNotice)
    }

    @Test("a replaced bundle is noticed")
    func replaced() {
        let disk = Disk(identity(1))
        let watcher = watcher(disk)
        disk.current = identity(2)
        watcher.check()
        #expect(watcher.isShowingNotice)
    }

    /// **The false alarm this has to avoid.** `install-app.sh` moves the old bundle aside
    /// and then moves the new one in; a poll landing between those two sees no file at all,
    /// a fraction of a second before there is anything to announce.
    @Test("a missing file mid-install is not a new build")
    func missingDuringSwap() {
        let disk = Disk(identity(1))
        let watcher = watcher(disk)
        disk.current = nil
        watcher.check()
        #expect(!watcher.isShowingNotice)

        disk.current = identity(2)
        watcher.check()
        #expect(watcher.isShowingNotice, "and it is noticed once the swap completes")
    }

    /// A rebuild landing on the same second still changes the inode, because the bundle is
    /// replaced rather than written to — but the size alone would miss it.
    @Test("an identical timestamp is still a different build")
    func sameTimestampDifferentInode() {
        let disk = Disk(identity(1, size: 1000))
        let watcher = watcher(disk)
        disk.current = identity(2, size: 1000)
        watcher.check()
        #expect(watcher.isShowingNotice)
    }

    @Test("Later hides it")
    func dismissal() {
        let disk = Disk(identity(1))
        let watcher = watcher(disk)
        disk.current = identity(2)
        watcher.check()
        watcher.dismiss()
        #expect(!watcher.isShowingNotice)

        // And stays hidden while that is still the build on disk.
        watcher.check()
        #expect(!watcher.isShowingNotice)
    }

    /// Waving one away must not silence every future build for the life of the process.
    @Test("a second install after a dismissal says so again")
    func dismissalIsPerBuild() {
        let disk = Disk(identity(1))
        let watcher = watcher(disk)
        disk.current = identity(2)
        watcher.check()
        watcher.dismiss()

        disk.current = identity(3)
        watcher.check()
        #expect(watcher.isShowingNotice)
    }

    /// Installing the running build back over itself leaves nothing to restart into.
    @Test("rolling back to the running build clears the notice")
    func rolledBack() {
        let disk = Disk(identity(1))
        let watcher = watcher(disk)
        disk.current = identity(2)
        watcher.check()
        #expect(watcher.isShowingNotice)

        disk.current = identity(1)
        watcher.check()
        #expect(!watcher.isShowingNotice)
    }

    /// Launched from somewhere that cannot be read — nothing to compare against, so it must
    /// stay quiet rather than announce a new build on every poll.
    @Test("an unreadable launch path never fires")
    func unreadableAtLaunch() {
        let disk = Disk(nil)
        let watcher = watcher(disk)
        disk.current = identity(2)
        watcher.check()
        #expect(!watcher.isShowingNotice)
    }

    @Test("identity reads a real file, and misses one that is not there")
    func identityOfARealFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "caravan-build-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)

        let read = try #require(BuildIdentity.of(file))
        #expect(read.size == 5)
        #expect(read.inode != 0)
        #expect(BuildIdentity.of(file) == read, "stable across reads")

        try FileManager.default.removeItem(at: file)
        #expect(BuildIdentity.of(file) == nil)
    }

    /// **The polling loop itself, against a real file.** The hand-driven `check()` tests
    /// above never start the timer, which is the part the running app depends on — and the
    /// first live attempt showed no banner, so "does `start()` work at all" needed an answer
    /// that was not a screenshot.
    @Test("start() notices a replaced file on its own")
    func timerFires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "caravan-timer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "binary")
        try Data("one".utf8).write(to: file)

        let watcher = BuildWatcher(executable: file, interval: .milliseconds(20))
        watcher.start()

        // Replaced the way the installer does it — a different file moved into place, so
        // the inode changes rather than the bytes being rewritten under the same one.
        let replacement = directory.appending(path: "incoming")
        try Data("two!".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)

        #expect(await waitUntil { watcher.isShowingNotice })
    }
}
