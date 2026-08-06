// swift-tools-version: 6.2
import PackageDescription

// Zero external dependencies, by rule. Scripts/check-docs.sh fails the build if a
// `.package(...)` entry appears here without an accompanying decision entry.

/// Applied to every target. Swift 6 language mode implies complete strict
/// concurrency.
///
/// Warnings-as-errors is deliberately *not* set here. `.treatAllWarnings(as: .error)`
/// becomes `-warnings-as-errors`, which conflicts with the `-suppress-warnings` Xcode
/// injects when it compiles package targets as dependencies of an app — the app build
/// fails outright. It is applied at the build invocation instead (see Makefile and
/// ci.yml), which covers `swift build`, `swift test` and CI.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

// The pure modules. No I/O, no Darwin, no AppKit — CI builds exactly these on Linux, so
// purity fails a build rather than depending on review. `IRCFormat` is here for the same
// reason `IRCProtocol` is: it is a table, tables are worth testing exhaustively, and a
// colour table that has to be exercised through a text view is a colour table nobody
// exercises.
let pureModules: [Target] = [
    .target(name: "IRCProtocol", swiftSettings: strict),
    .testTarget(
        name: "IRCProtocolTests",
        dependencies: ["IRCProtocol"],
        resources: [.copy("Fixtures")],
        swiftSettings: strict
    ),
    .target(name: "IRCFormat", swiftSettings: strict),
    .testTarget(name: "IRCFormatTests", dependencies: ["IRCFormat"], swiftSettings: strict),
]

// Everything else needs Darwin: os.Logger, Network.framework, AppKit.
let darwinOnly: [Target] = [
    .target(name: "Diagnostics", swiftSettings: strict),
    .target(
        name: "IRCTransport",
        dependencies: ["Diagnostics", "IRCProtocol"],
        swiftSettings: strict
    ),
    .target(
        name: "IRCSession",
        dependencies: ["Diagnostics", "IRCProtocol", "IRCTransport"],
        swiftSettings: strict
    ),
    // The AppKit and SwiftUI layer. A library rather than app-target source so the
    // scrollback view — the load-bearing component — can be unit-tested and benchmarked;
    // nothing in an `.xcodeproj` app target is reachable from `swift test`.
    .target(
        name: "CaravanUI",
        dependencies: ["Diagnostics", "IRCFormat", "IRCProtocol", "IRCSession"],
        swiftSettings: strict
    ),
    .testTarget(
        name: "CaravanUITests",
        dependencies: ["CaravanUI", "CaravanTestSupport"],
        swiftSettings: strict
    ),
    // A loopback IRC server the transport and session suites both drive. A plain target
    // rather than a test target, because SwiftPM has no way for one test target to
    // depend on another; it is in no product, so it never reaches a consumer.
    .target(
        name: "CaravanTestSupport",
        dependencies: ["IRCProtocol", "IRCTransport"],
        path: "Tests/Support",
        swiftSettings: strict
    ),
    .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"], swiftSettings: strict),
    .testTarget(
        name: "IRCTransportTests",
        dependencies: ["IRCTransport", "CaravanTestSupport"],
        swiftSettings: strict
    ),
    .testTarget(
        name: "IRCSessionTests",
        dependencies: ["IRCSession", "CaravanTestSupport"],
        swiftSettings: strict
    ),
]

let pureProducts: [Product] = [
    .library(name: "IRCProtocol", targets: ["IRCProtocol"]),
    .library(name: "IRCFormat", targets: ["IRCFormat"]),
]

let darwinProducts: [Product] = [
    .library(name: "Diagnostics", targets: ["Diagnostics"]),
    .library(name: "IRCTransport", targets: ["IRCTransport"]),
    .library(name: "IRCSession", targets: ["IRCSession"]),
    .library(name: "CaravanUI", targets: ["CaravanUI"]),
]

// On Linux the package is deliberately reduced to the pure module and its tests.
//
// Without this, `swift test` on the purity runner would try to build Diagnostics —
// which imports os.Logger — and fail for a reason that has nothing to do with
// purity. Shrinking the manifest instead lets that job actually *run* the parser
// tests cross-platform rather than merely compiling the module.
#if os(Linux)
    let allTargets = pureModules
    let allProducts: [Product] = pureProducts
#else
    let allTargets = pureModules + darwinOnly
    let allProducts: [Product] = pureProducts + darwinProducts
#endif

let package = Package(
    name: "Caravan",
    platforms: [.macOS(.v15)],
    products: allProducts,
    targets: allTargets
)
