import CaravanUI
import SwiftUI

/// Application entry point.
///
/// Deliberately thin: the interface lives in the `CaravanUI` library, where `swift test`
/// can reach it. Nothing inside an app target is testable or benchmarkable, and the
/// scrollback has to be both.
///
/// The window title comes from `CFBundleDisplayName` ("Caravan") rather than
/// being hard-coded here, so the rename gated in PLAN.md touches one build setting
/// instead of source.
@main
struct CaravanApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 900, height: 600)
    }
}
