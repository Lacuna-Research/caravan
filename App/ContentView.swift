import SwiftUI

/// Empty shell proving the app builds, launches, and lays out.
///
/// The sidebar fills with networks and channels in prompt 8; the detail pane gets
/// the `NSTextView`-backed scrollback and input field in prompt 7. Deliberately
/// nothing else here — see the scope fence on prompt 1.
struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {}
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
        } detail: {
            Color.clear
        }
    }
}

#Preview {
    ContentView()
}
