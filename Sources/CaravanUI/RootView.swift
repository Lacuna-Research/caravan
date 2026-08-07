import SwiftUI

/// The window: the buffer tree, and the selected buffer beside it.
public struct RootView: View {
    /// Owned by the app rather than by this view, so the menu bar can reach it too.
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self._model = Bindable(wrappedValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            SidebarTree(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
        } detail: {
            detail
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        }
        // Set once, read by every buffer, the tree, the nick list and the input box —
        // one chat font, which is the requirement rather than a convenience.
        .environment(
            \.chatFont,
            ChatFont.font(family: model.settings.fontFamily, size: model.settings.fontSize)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                closeChannelButton
            }
            // **Both, not one or the other.** They used to alternate, which was right when
            // there could be one connection: "connect" meant "connect *this*". Now it means
            // "open another network", so hiding it while one is connected leaves no way to
            // reach the second one — which is the entire feature. Found by the live run.
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect") {
                    Task { await model.disconnect() }
                }
                .disabled(model.activeConnection?.isConnected != true)
                .help("Disconnect the selected network")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Connect…") { model.isShowingConnectSheet = true }
                    .help("Open another network")
            }
        }
        .sheet(isPresented: $model.isShowingConnectSheet) {
            ConnectSheet(config: model.config, credentials: model.credentials) { settings in
                Task { await model.connect(using: settings) }
            }
        }
        // The TLS handshake is genuinely paused behind this one, so it takes precedence
        // over whatever else is on screen.
        .sheet(item: $model.pendingTrust) { request in
            TrustSheet(request: request)
        }
    }

    @ViewBuilder
    private var detail: some View {
        // The canvas replaces the chat area, and takes precedence over whatever buffer
        // was selected — which is what makes selecting a buffer bring the chat area back.
        if model.isShowingCanvas {
            SettingsDebugCanvas(model: model)
        } else if let connection = model.activeConnection {
            if let buffer = model.selectedChannel {
                ChannelBufferView(model: model, buffer: buffer)
            } else if let buffer = model.selectedQuery {
                QueryBufferView(model: model, buffer: buffer)
            } else {
                StatusBufferView(model: model, connection: connection)
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

    /// The title names the buffer you are in; the subtitle names the network it belongs
    /// to — the same "always say which network" rule the tree follows, since `#music` on
    /// two networks are different rooms.
    private var title: String {
        if model.isShowingCanvas { return "Settings & Debug" }
        if let channel = model.selectedChannel { return channel.name.raw }
        if let query = model.selectedQuery { return query.nick.raw }
        return model.activeConnection?.displayName ?? "Caravan"
    }

    private var subtitle: String {
        guard !model.isShowingCanvas, let connection = model.activeConnection else { return "" }
        return model.selectedTarget == nil ? connection.statusSummary : connection.displayName
    }

    /// ⌘W closes the selected buffer. On a channel that *parts* it — membership never
    /// outlives its buffer — and on a conversation it closes a window and nothing more.
    ///
    /// The title says which, because the two are not the same act. Disabled when neither
    /// is selected, so the shortcut falls back to the window's own Close rather than
    /// swallowing it: a status window is not closable, being the network row, and closing
    /// a network is disconnecting from it.
    private var closeChannelButton: some View {
        Button(model.closeBufferTitle ?? "Close Channel") {
            Task { await model.closeSelectedBuffer() }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(model.closeBufferTitle == nil)
        .help(
            model.selectedQuery != nil
                ? "Close this conversation's window"
                : "Close this channel's buffer and part the channel"
        )
    }
}

/// The network's status window: everything not addressed to a channel.
struct StatusBufferView: View {
    let model: AppModel
    let connection: ConnectionViewModel

    @Environment(\.chatFont) private var chatFont
    @State private var isMOTDExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollbackView(log: connection.log)
            Divider()
            inputField
        }
    }

    /// The status window's header band, showing the MOTD.
    ///
    /// The MOTD is long and multi-line, which makes the shrink behaviour load-bearing
    /// here rather than an edge case — the band is never hidden and never closable, so it
    /// has to be able to be small. Connection state rides in the trailing corner, because
    /// the one thing a user wants when a connection drops is to know why.
    private var header: some View {
        HeaderBand(
            content: connection.motd,
            placeholder: connection.statusSummary,
            isExpanded: $isMOTDExpanded
        ) {
            HStack(spacing: 8) {
                rawTrafficToggle
                Circle()
                    .fill(connection.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .help(connection.statusSummary)
                    .accessibilityLabel(connection.statusSummary)
            }
        }
        .font(chatFont)
    }

    /// Wire traffic, both directions, `>>` and `<<`.
    ///
    /// Turning it on starts appending from that moment rather than interleaving what came
    /// before — mIRC's `/debug` behaviour, and prompt 11's `-i` flag is what reaches back
    /// into the ring buffer for the history.
    private var rawTrafficToggle: some View {
        Button {
            model.settings.showsRawTraffic.toggle()
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(
                    model.settings.showsRawTraffic ? Color.accentColor : Color.secondary
                )
        }
        .buttonStyle(.plain)
        .help(
            model.settings.showsRawTraffic
                ? "Stop showing raw wire traffic" : "Show raw wire traffic"
        )
        .accessibilityLabel("Raw wire traffic")
    }

    /// A status window has no target, so plain text has nowhere to go and says so.
    /// Commands work here, which is what makes `/join` and `/server` reachable before
    /// there is any channel to type in.
    private var inputField: some View {
        InputBar(
            state: connection.statusInput,
            target: nil,
            placeholder: "/command",
            // No nicks: a status window has no membership, and offering the nicks of some
            // other channel here would complete to people who cannot see the line.
            sources: { model.completionSources(in: nil) },
            palette: model.settings.palette,
            completionStyle: model.settings.completionSuffix,
            submit: { text in
                await model.submit(text, from: nil)
            }
        )
    }
}
