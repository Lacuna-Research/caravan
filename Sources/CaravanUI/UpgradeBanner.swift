import SwiftUI

/// "A newer build is installed" — the bar that appears when the app on disk stops being the
/// app that is running.
///
/// **Not an alert and not a sheet.** This is news rather than a question: the running copy
/// is still perfectly usable, and interrupting somebody mid-sentence to tell them a build
/// they did not ask for has landed would be worse than the confusion it prevents. It sits
/// above the chat area, takes one line, and goes away when told to.
struct UpgradeBanner: View {
    let watcher: BuildWatcher

    var body: some View {
        if watcher.isShowingNotice {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Text("A newer build of Caravan is installed. Restart to use it.")
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Later") { watcher.dismiss() }
                Button("Restart") { watcher.restart() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("A newer build of Caravan is installed")
        }
    }
}
