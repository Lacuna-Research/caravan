import Foundation
import Testing

@testable import CaravanUI

/// The diagnostic that only exists when asked for.
@Suite("Timing log")
struct TimingLogTests {
    /// **Off unless switched on, and the switch is a file.** A double-clicked app never
    /// sees a shell's environment, so an environment-variable diagnostic is one that cannot
    /// be used from where the problems get reported.
    ///
    /// Asked of the pure decision rather than of `isEnabled`, which reads the developer's
    /// own home directory — the first version of this test passed until somebody switched
    /// the log on to use it, and then failed on a machine where nothing was wrong.
    @Test("the switch file turns it on; the environment variable also does")
    func enablingRules() {
        #expect(!TimingLog.shouldEnable(environment: [:], switchExists: false))
        #expect(TimingLog.shouldEnable(environment: [:], switchExists: true))
        #expect(
            TimingLog.shouldEnable(environment: ["CARAVAN_TIMING_LOG": "1"], switchExists: false)
        )
        // Any value at all, including empty: the variable being present is the request.
        #expect(
            TimingLog.shouldEnable(environment: ["CARAVAN_TIMING_LOG": ""], switchExists: false)
        )
        #expect(!TimingLog.shouldEnable(environment: ["SOMETHING_ELSE": "1"], switchExists: false))
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

    /// **The arithmetic the first version got wrong.** `Duration.components` is
    /// (seconds, attoseconds); reading only the attoseconds gives the fractional part, so a
    /// line twenty-nine seconds in logged as 0.030 and the column meant for measuring gaps
    /// could not measure one longer than a second.
    @Test("elapsed seconds survive passing a second")
    func elapsedUsesBothComponents() {
        let short = Duration.milliseconds(30).components
        let long = Duration.seconds(29) + Duration.milliseconds(30)

        #expect(TimingLog.seconds(of: short) == 0.03)
        #expect(abs(TimingLog.seconds(of: long.components) - 29.03) < 0.0001)
    }

    @Test("the cache directory follows XDG, like the other two")
    func cacheHonoursXDG() {
        #expect(AppDirectories.cache.lastPathComponent == "caravan")
        #expect(AppDirectories.cache.path.contains("caravan"))
    }
}
