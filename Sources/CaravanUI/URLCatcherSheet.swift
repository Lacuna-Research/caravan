import AppKit
import SwiftUI

extension View {
    /// Presents the URL catcher when it was asked for *from this window*.
    ///
    /// Bound to which window opened it rather than to a plain flag, so a link right-clicked
    /// in a detached buffer does not put its sheet on the main window behind it.
    func urlCatcher(model: AppModel, in window: KeyWindow) -> some View {
        sheet(
            isPresented: Binding(
                get: { model.urlCatcherPresentation?.window == window },
                set: { if !$0 { model.urlCatcherPresentation = nil } }
            )
        ) {
            if let presentation = model.urlCatcherPresentation {
                URLCatcherSheet(catcher: model.urlCatcher, presentation: presentation)
            }
        }
    }
}

/// Every URL the client has drawn, newest first.
///
/// mIRC's URL catcher, which is a list and two buttons — the whole value of the feature is
/// that the link somebody posted twenty minutes ago is still findable, so the window earns
/// its place by being boring.
struct URLCatcherSheet: View {
    let catcher: URLCatcher
    let presentation: AppModel.URLCatcherPresentation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatFont) private var chatFont

    @State private var scope: URLCatcherScope = .buffer
    @State private var selection: URLCatcher.Entry.ID?
    @State private var isConfirmingOpenAll = false

    /// Above this many, Open All asks first. Three or four tabs is what the button is for;
    /// forty is a mis-click, and a client should not be able to do that without a question.
    private static let openAllWithoutAsking = 5

    private var entries: [URLCatcher.Entry] {
        catcher.entries(in: scope, network: presentation.network, buffer: presentation.buffer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            scopePicker
            list
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 560, height: 420)
        .confirmationDialog(
            "Open \(entries.count) links in your browser?",
            isPresented: $isConfirmingOpenAll
        ) {
            Button("Open \(entries.count) Links") { openAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("URL Catcher").font(.headline)
            Text(entries.isEmpty ? "Nothing caught yet." : "\(entries.count) links, newest first")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// **Starts on this buffer.** The catcher is nearly always opened because of a link you
    /// just saw scroll past, and a window that opened on every network's history would make
    /// you filter down to where you already were.
    private var scopePicker: some View {
        Picker("", selection: $scope) {
            ForEach(URLCatcherScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(presentation.buffer == nil)
    }

    @ViewBuilder
    private var list: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No links here", systemImage: "link.badge.plus")
            } description: {
                Text("Links people post appear here as they arrive.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries, selection: $selection) { entry in
                row(entry)
                    .tag(entry.id)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { open(entry) }
                    .contextMenu {
                        Button("Open Link") { open(entry) }
                        Button("Copy Link") { AppModel.copyToPasteboard(entry.url.absoluteString) }
                    }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: URLCatcher.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.url.absoluteString)
                .font(chatFont)
                .lineLimit(1)
                .truncationMode(.middle)
            // Always says which network, the same rule the tree follows: `#music` on two
            // networks are different rooms, and so are their links.
            Text(
                "\(entry.buffer) on \(entry.network) \u{00b7} \(entry.date.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy All") { copyAll() }
                .disabled(entries.isEmpty)
            Button("Open All") { confirmOpenAll() }
                .disabled(entries.isEmpty)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func open(_ entry: URLCatcher.Entry) {
        NSWorkspace.shared.open(entry.url)
    }

    private func copyAll() {
        AppModel.copyToPasteboard(entries.map(\.url.absoluteString).joined(separator: "\n"))
    }

    private func confirmOpenAll() {
        guard entries.count > Self.openAllWithoutAsking else {
            openAll()
            return
        }
        isConfirmingOpenAll = true
    }

    private func openAll() {
        // Oldest first, so the browser ends up with the newest link in the frontmost tab —
        // the reverse of the order the list reads in, and the right one for tabs.
        for entry in entries.reversed() { open(entry) }
    }
}
