import SwiftUI

/// Application entry point.
///
/// The window title comes from `CFBundleDisplayName` ("IRC Client") rather than
/// being hard-coded here, so the rename gated in PLAN.md touches one build setting
/// instead of source.
@main
struct IRCClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 600)
    }
}
