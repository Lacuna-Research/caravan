// swift-tools-version: 6.2
import PackageDescription

// Zero external dependencies, by rule. Scripts/check-docs.sh fails the build if a
// `.package(...)` entry appears here without an accompanying decision entry.

/// Applied to every target. Swift 6 language mode implies complete strict
/// concurrency; treating warnings as errors makes the zero-warnings rule the
/// compiler's job rather than a promise we audit ourselves.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
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
