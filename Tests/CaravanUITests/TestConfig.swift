import Foundation

@testable import CaravanUI

/// A config file of this test's own, in a temporary directory.
///
/// `ChatSettings` and the Connect sheet persist on write, and a test suite has no
/// business editing the settings of whoever runs it. A fresh path per call also means two
/// tests running in parallel cannot see each other's writes.
@MainActor
func temporaryConfig() -> ConfigFile {
    ConfigFile(url: temporaryDirectory().appending(path: "caravan.conf"))
}

/// A known-hosts file of this test's own, for the same reason.
@MainActor
func temporaryKnownHosts() -> KnownHosts {
    KnownHosts(url: temporaryDirectory().appending(path: "known_hosts"))
}

/// A model with nothing of the user's under it: its own config, its own known hosts, and
/// **a credential store that is not the login keychain**. The last one matters most — a
/// suite that wrote passwords into the developer's keychain would leave them there.
@MainActor
func temporaryModel() -> AppModel {
    AppModel(
        config: temporaryConfig(),
        knownHosts: temporaryKnownHosts(),
        credentials: EphemeralCredentialStore()
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "caravan-tests-\(UUID().uuidString)")
}
