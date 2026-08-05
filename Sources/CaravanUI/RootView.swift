import SwiftUI

/// The window: a sidebar of buffers, and the selected buffer's scrollback with an input
/// field under it.
public struct RootView: View {
    @State private var model = AppModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
        } detail: {
            if let connection = model.connection {
                BufferView(connection: connection)
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
        .toolbar {
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

    private var sidebar: some View {
        List(selection: $model.selection) {
            if let connection = model.connection {
                Section(connection.displayName) {
                    Label(connection.displayName, systemImage: "bubble.left.and.bubble.right")
                        .tag(AppModel.SidebarItem.status(connection.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One buffer: scrollback, a status line, and the input field.
struct BufferView: View {
    let connection: ConnectionViewModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            scrollback
            Divider()
            inputField
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            statusBar
        }
    }

    private var scrollback: some View {
        MessageLogView(controller: connection.log)
            .overlay(alignment: .bottomTrailing) {
                // Only offered when it is needed: while pinned to the bottom there is no
                // "latest" to jump to.
                if !connection.log.isPinnedToBottom {
                    Button {
                        connection.log.scrollToLatest()
                    } label: {
                        Label(
                            connection.log.unseenLineCount > 0
                                ? "\(connection.log.unseenLineCount) new" : "Jump to latest",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(12)
                }
            }
    }

    /// Connection state belongs on screen, not only in the console — including *why* a
    /// connection dropped, which is the one thing a user wants when it does.
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
