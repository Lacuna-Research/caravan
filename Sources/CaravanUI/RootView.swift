import SwiftUI

/// The window: the buffer tree, and the selected buffer beside it.
public struct RootView: View {
    @State private var model = AppModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarTree(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                closeChannelButton
            }
            ToolbarItem(placement: .primaryAction) {
                if model.connection?.isConnected == true {
                    Button("Disconnect") {
                        Task { await model.disconnect() }
                    }
                } else {
                    Button("Connect…") { model.isShowingConnectSheet = true }
                }
            }
        }
        .sheet(isPresented: $model.isShowingConnectSheet) {
            ConnectSheet { settings in
                Task { await model.connect(using: settings) }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let connection = model.connection {
            if let buffer = model.selectedChannel {
                ChannelBufferView(connection: connection, buffer: buffer)
            } else {
                StatusBufferView(connection: connection)
            }
        } else {
            ContentUnavailableView {
                Label("Not connected", systemImage: "network.slash")
            } description: {
                Text("Connect to an IRC network to get started.")
            } actions: {
                Button("Connect…") { model.isShowingConnectSheet = true }
            }
        }
    }

    /// ⌘W closes the selected *channel*, which parts it — membership never outlives its
    /// buffer.
    ///
    /// Disabled when no channel is selected, so the shortcut falls back to the window's
    /// own Close rather than swallowing it. A status window is not closable: it is the
    /// network row, and closing a network is disconnecting from it.
    private var closeChannelButton: some View {
        Button("Close Channel") {
            Task { await model.closeSelectedChannel() }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(model.selectedChannel == nil)
        .help("Close this channel's buffer and part the channel")
    }
}

/// The network's status window: everything not addressed to a channel.
struct StatusBufferView: View {
    let connection: ConnectionViewModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollbackView(log: connection.log)
            Divider()
            inputField
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            statusBar
        }
    }

    /// Connection state belongs on screen, not only in the console — including *why* a
    /// connection dropped, which is the one thing a user wants when it does.
    ///
    /// Prompt 10 replaces this with the status window's own header band, showing the
    /// MOTD; the tree's network row already carries the same state as a dot.
    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connection.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(connection.statusSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var inputField: some View {
        TextField("Send a raw IRC line…", text: $input)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .onSubmit(send)
    }

    private func send() {
        let text = input
        input = ""
        Task { await connection.send(rawLine: text) }
    }
}
