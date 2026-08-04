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

let package = Package(
    name: "IRCClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "IRCProtocol", targets: ["IRCProtocol"]),
        .library(name: "IRCTransport", targets: ["IRCTransport"]),
        .library(name: "IRCSession", targets: ["IRCSession"]),
    ],
    targets: [
        // Logging, redaction, wire tracing. Darwin-only (os.Logger).
        .target(name: "Diagnostics", swiftSettings: strict),

        // Message parsing and serialization. Pure: no I/O, no Foundation
        // networking, no Darwin APIs. CI builds this target alone on Linux, so a
        // platform import here fails the build rather than a review.
        .target(name: "IRCProtocol", swiftSettings: strict),

        // Sockets, TLS, line framing.
        .target(
            name: "IRCTransport",
            dependencies: ["Diagnostics", "IRCProtocol"],
            swiftSettings: strict
        ),

        // Registration, connection state machine, event stream.
        .target(
            name: "IRCSession",
            dependencies: ["Diagnostics", "IRCProtocol", "IRCTransport"],
            swiftSettings: strict
        ),

        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"], swiftSettings: strict),
        .testTarget(name: "IRCProtocolTests", dependencies: ["IRCProtocol"], swiftSettings: strict),
        .testTarget(
            name: "IRCTransportTests",
            dependencies: ["IRCTransport"],
            swiftSettings: strict
        ),
        .testTarget(name: "IRCSessionTests", dependencies: ["IRCSession"], swiftSettings: strict),
    ]
)
