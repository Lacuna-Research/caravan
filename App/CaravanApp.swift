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
            // ⌘, opens the canvas rather than a Settings *window*. Forty years of muscle
            // memory makes a dead ⌘, conspicuous, and macOS's own convention — Settings is
            // a separate window, always — is the thing being departed from deliberately
            // here (GUI-DESIGN-NOTES.md §10).
            CommandGroup(replacing: .appSettings) {
                Button("Settings & Debug…") { model.showSettingsAndDebug() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘0 is the canvas's place in the buffer-navigation numbering: ⌘1…⌘9 reach
            // buffers, and the canvas is the one that is not one. Listed in View rather
            // than duplicated into the app menu's item, because two menu items with the
            // same name in the same menu is how you make both unfindable.
            CommandGroup(after: .sidebar) {
                Button("Settings & Debug") { model.showSettingsAndDebug() }
                    .keyboardShortcut("0", modifiers: .command)
            }
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
