import CaravanUI
import SwiftUI

/// Application entry point.
///
/// Deliberately thin: the interface lives in the `CaravanUI` library, where `swift test`
/// can reach it. Nothing inside an app target is testable or benchmarkable, and the
/// scrollback has to be both.
///
/// The model is owned here rather than by `RootView` for one reason: the menu bar has to
/// reach it, and a `@State` declared inside a view does not carry out to `.commands`.
///
/// The window title comes from `CFBundleDisplayName` ("Caravan") rather than
/// being hard-coded here, so the rename gated in PLAN.md touches one build setting
/// instead of source.
@main
struct CaravanApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .pasteboard) {
                // The redacted wire trace plus the app and OS version. Safe to paste into
                // a public issue, because the trace was redacted on insert rather than on
                // the way out.
                Button("Copy Diagnostics") {
                    model.copyDiagnostics()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
