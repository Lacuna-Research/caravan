import Foundation

@testable import CaravanUI

/// A config file of this test's own, in a temporary directory.
///
/// `ChatSettings` and the Connect sheet persist on write, and a test suite has no
/// business editing the settings of whoever runs it. A fresh path per call also means two
/// tests running in parallel cannot see each other's writes.
@MainActor
func temporaryConfig() -> ConfigFile {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "caravan-tests-\(UUID().uuidString)")
        .appending(path: "caravan.conf")
    return ConfigFile(url: url)
}
