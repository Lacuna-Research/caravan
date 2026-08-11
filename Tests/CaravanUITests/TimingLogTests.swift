import Foundation
import Testing

@testable import CaravanUI

/// The diagnostic that only exists when asked for.
@Suite("Timing log")
struct TimingLogTests {
    /// **Off unless switched on, and the switch is a file.** A double-clicked app never sees
    /// a shell's environment, so an environment-variable diagnostic is one that cannot be
    /// used from where the problems get reported.
    @Test("it is off in an ordinary run, and writes nothing")
    func offByDefault() {
        // The suite runs without the switch file and without the variable.
        #expect(!TimingLog.isEnabled)

        TimingLog.note("this must not appear anywhere")
        #expect(
            !FileManager.default.fileExists(atPath: TimingLog.logURL.path)
                || !((try? String(contentsOf: TimingLog.logURL, encoding: .utf8))?
                    .contains("this must not appear anywhere") ?? false)
        )
    }

    @Test("measure returns what the work returned, switched on or off")
    func measurePassesValueThrough() {
        #expect(TimingLog.measure("adding") { 2 + 2 } == 4)
    }

    /// The switch and the log sit in the cache directory, which is the one place it would be
    /// no loss to delete.
    @Test("both paths are under the cache directory")
    func pathsAreInTheCache() {
        // Compared as paths: a directory URL carries a trailing slash and a file URL's
        // parent does not, so the two are unequal while naming the same directory.
        #expect(TimingLog.logURL.deletingLastPathComponent().path == AppDirectories.cache.path)
        #expect(TimingLog.switchURL.deletingLastPathComponent().path == AppDirectories.cache.path)
        #expect(TimingLog.logURL.lastPathComponent == "timing.log")
        #expect(TimingLog.switchURL.lastPathComponent == "timing.on")
    }

    @Test("the cache directory follows XDG, like the other two")
    func cacheHonoursXDG() {
        #expect(AppDirectories.cache.lastPathComponent == "caravan")
        #expect(AppDirectories.cache.path.contains("caravan"))
    }
}
