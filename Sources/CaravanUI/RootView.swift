import SwiftUI

/// The window: the buffer tree, and the selected buffer beside it.
public struct RootView: View {
    /// Owned by the app rather than by this view, so the menu bar can reach it too.
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self._model = Bindable(wrappedValue: model)
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.controlActiveState) private var activeState

    public var body: some View {
        NavigationSplitView {
            SidebarTree(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
        } detail: {
            // **A `VStack`, not `safeAreaInset`.** The banner has to *move* the content, not
            // float over it: as a safe-area inset it drew across the top of whatever was
            // below — the Dashboard's first rows were simply hidden behind it. Stacked, it
            // takes real layout space, and takes none at all when there is nothing to say,
            // because `UpgradeBanner` resolves to nothing when the notice is not showing.
            //
            // Above the chat area rather than in a sheet or an alert: being told a newer
            // build exists is news, not a question, and it must not stop somebody finishing
            // the sentence they were typing.
            VStack(spacing: 0) {
                UpgradeBanner(watcher: model.buildWatcher)
                detail
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        // **Asked on activation as well as on the timer.** Somebody who has just run
        // `make install` in a terminal switches straight back to the app, which is exactly
        // when a minute of polling delay feels like the feature not working.
        .onChange(of: activeState) { _, state in
            TimingLog.note("window active state: \(state)")
            if state != .inactive { model.buildWatcher.check() }
        }
        // The three moments a "clicks are being ignored" report is about: when the window
        // was there to click, when the click arrived, and when anything happened as a
        // result. All three are off unless `~/.cache/caravan/timing.on` exists.
        .task {
            TimingLog.note("window shown")
            TimingLog.watchMouseDowns()
        }
        // Set once, read by every buffer, the tree, the nick list and the input box —
        // one chat font, which is the requirement rather than a convenience.
        .environment(
            \.chatFont,
            model.settings.chatFont
        )
        // **No toolbar at all** (§8, revised). Its three items were each overtaken by
        // something already on screen: the connection state duplicated the window
        // subtitle *and* the dot on every network row, the `+` duplicated the Dashboard
        // row pinned at the top of the tree, and the nick-list toggle wore
        // `sidebar.right` inches from the real sidebar toggle. Every one of them is a
        // menu item with a keyboard shortcut, which is where they now live alone.
        // The TLS handshake is genuinely paused behind this one, so it takes precedence
        // over whatever else is on screen.
        .sheet(item: $model.pendingTrust) { request in
            TrustSheet(request: request)
        }
        .sheet(isPresented: $model.isShowingQuickSwitcher) {
            QuickSwitcher(model: model)
        }
        .sheet(isPresented: $model.isShowingChannelModes) {
            if let buffer = model.selectedChannel, let connection = model.activeConnection {
                ChannelModesSheet(model: model, connection: connection, buffer: buffer)
            }
        }
        .urlCatcher(model: model, in: .main)
        .logViewer(model: model, in: .main)
        // **Nothing called this.** Prompt 11 built `connectStartupServers()`, wrote the
        // toggle and the `connect-on-startup` key, tested the method — and never gave it a
        // caller, so the setting has been shipped doing nothing. Found by prompt 12's live
        // run, where a `servers.conf` with the flag set produced a Dashboard that just sat
        // there. `.task` rather than `.onAppear` because connecting is `async`, and it runs
        // once for the main window's lifetime.
        .task { await model.connectStartupServers() }
        // Asked once, on launch, and only in an app bundle. Also puts the menu-bar item up
        // if the setting says so, which nothing else would do before the first highlight.
        .task { model.startAlerts() }
        // Ctrl+Tab needs the modifier's *release*, which no SwiftUI shortcut can express.
        .modifier(CtrlTabModifier(model: model))
        .onChange(of: activeState, initial: true) { _, state in
            if state == .key { model.keyWindow = .main }
        }
        // `openWindow` and `dismissWindow` are environment values, so only a view can call
        // them. The model asks by setting a property; this clears it once acted on.
        .onChange(of: model.windowToFocus) { _, item in
            guard let item else { return }
            openWindow(id: RootView.detachedWindowID, value: item)
            model.windowToFocus = nil
        }
        .onChange(of: model.windowToClose) { _, item in
            guard let item else { return }
            dismissWindow(id: RootView.detachedWindowID, value: item)
            model.windowToClose = nil
        }
    }

    /// The `WindowGroup` every detached buffer opens in.
    public static let detachedWindowID = "caravan.buffer"

    @ViewBuilder
    private var detail: some View {
        // A buffer cannot be in two places, so the chat area says where it went rather
        // than drawing a second copy of it.
        if let selection = model.selection, model.isDetached(selection) {
            DetachedElsewhere(model: model, item: selection)
        } else if model.selection == .dashboard {
            DashboardCanvas(model: model)
        } else if let selection = model.selection,
            let connection = model.channelListConnection(of: selection)
        {
            ChannelListCanvas(model: model, connection: connection)
        } else if model.isShowingCanvas {
            SettingsDebugCanvas(model: model)
        } else if let connection = model.activeConnection {
            if let buffer = model.selectedChannel {
                ChannelBufferView(model: model, connection: connection, buffer: buffer)
            } else if let buffer = model.selectedQuery {
                QueryBufferView(model: model, connection: connection, buffer: buffer)
            } else {
                StatusBufferView(model: model, connection: connection)
            }
        } else {
            // Nothing selected and nothing connected: show the front door rather than a
            // placeholder with a button that opens the front door (§13).
            DashboardCanvas(model: model)
        }
    }

    /// The title names the buffer you are in; the subtitle names the network it belongs
    /// to — the same "always say which network" rule the tree follows, since `#music` on
    /// two networks are different rooms.
    private var title: String {
        model.selection.map { model.title(of: $0) } ?? "Caravan"
    }

    private var subtitle: String {
        guard !model.isShowingCanvas, let connection = model.activeConnection else { return "" }
        return model.selectedTarget == nil ? connection.statusSummary : connection.displayName
    }

}

/// The chat area for a buffer that is in a window of its own.
///
/// Says where it went and offers both ways back — raise that window, or bring it home.
/// An empty pane would read as a bug, and the window it belongs to may well be behind
/// this one.
private struct DetachedElsewhere: View {
    let model: AppModel
    let item: AppModel.SidebarItem

    var body: some View {
        ContentUnavailableView {
            Label("In its own window", systemImage: "macwindow.on.rectangle")
        } description: {
            Text("\(model.title(of: item)) is open in a separate window.")
        } actions: {
            Button("Bring to Front") { model.windowToFocus = item }
            Button("Bring Back Into Main Window") { model.reattach(item) }
        }
    }
}

/// The network's status window: everything not addressed to a channel.
struct StatusBufferView: View {
    let model: AppModel
    let connection: ConnectionViewModel

    /// Which window this view is in, so a sheet opened from it lands on the right one.
    var window: KeyWindow = .main

    @Environment(\.chatFont) private var chatFont
    @State private var isMOTDExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollbackView(log: connection.log, actions: actions)
            Divider()
            inputField
        }
    }

    /// No channel and no target: a status window is where the *network* talks, so the only
    /// thing its scrollback offers is what to do with a link in the MOTD.
    private var actions: BufferActions {
        BufferActions(
            model: model,
            connection: connection,
            channel: nil,
            target: nil,
            window: window
        )
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
            sources: { model.completionSources(in: nil, on: connection) },
            palette: model.settings.palette,
            completionStyle: model.settings.completionSuffix,
            submit: { text in
                await model.submit(text, from: nil, on: connection)
            }
        )
    }
}
