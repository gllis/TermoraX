//
//  ContentView.swift
//  TermoraX
//
//  主界面：左侧会话树、中间标签 + 终端、右侧 SFTP、底部快速命令。
//  面板显隐与宽度写入 AppStorage；打开的标签由 WorkspaceController 定时快照。
//

import SwiftData
import SwiftUI
import AppKit

/// 主窗口内容。三栏布局，工具栏切换面板，sheet 编辑会话与快速命令。
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \SessionNode.sortIndex) private var nodes: [SessionNode]
    @Query(sort: \QuickCommand.sortIndex) private var commands: [QuickCommand]
    @State private var workspace = WorkspaceController()
    @Bindable private var settings = AppSettings.shared

    @AppStorage("sessionPanelPinned") private var sessionPinned = true
    @AppStorage("filePanelPinned") private var filePinned = false
    @AppStorage("commandPanelPinned") private var commandPinned = true
    @AppStorage("sessionPanelWidth") private var storedSessionWidth = 260.0
    @AppStorage("filePanelWidth") private var storedFileWidth = 520.0
    @AppStorage("commandPanelHeight") private var storedCommandHeight = 156.0
    @State private var sessionWidth: CGFloat = 260
    @State private var fileWidth: CGFloat = 520
    @State private var commandHeight: CGFloat = 156
    @State private var sftpHint = false

    var body: some View {
        HStack(spacing: 0) {
            sessionColumn
            mainColumn
            fileColumn
        }
        .animation(.easeInOut(duration: 0.18), value: sessionPinned)
        .animation(.easeInOut(duration: 0.18), value: filePinned)
        .animation(.easeInOut(duration: 0.18), value: workspace.commandPanelExpanded)
        .toolbar { toolbar }
        .sheet(item: $workspace.pendingEdit) { token in
            SessionEditorView(token: token)
        }
        .sheet(isPresented: $workspace.showNewCommand) {
            QuickCommandEditorView()
        }
        .sheet(item: $workspace.pendingCommandEdit) { command in
            QuickCommandEditorView(command: command)
        }
        .background(WindowIdentifierSetter())
        .onAppear {
            sessionWidth = storedSessionWidth
            fileWidth = storedFileWidth
            commandHeight = storedCommandHeight
            SeedData.populateIfNeeded(in: modelContext)
            AppDelegate.workspace = workspace
            workspace.restoreActivity(nodes: nodes)
        }
        .onChange(of: settings.terminalFontSize) { _, size in
            TerminalRegistry.shared.applyFontSize(size)
        }
        .onChange(of: settings.zmodemReceivePath) { _, _ in
            TerminalRegistry.shared.applyZModemFolder()
        }
        .onChange(of: settings.activitySaveInterval) { _, _ in
            workspace.rescheduleActivitySave()
        }
        .onChange(of: workspace.selectedTabID) { _, _ in
            workspace.persistActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: .termoraNewSession)) { _ in
            workspace.pendingEdit = .newSession(parent: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termoraNewGroup)) { _ in
            workspace.pendingEdit = .newGroup(parent: nil)
        }
        .alert("请先连接主机", isPresented: $sftpHint) {
            Button("好", role: .cancel) {}
        } message: {
            Text("SFTP 需要已连接的 SSH 会话。请先在左侧双击主机，或在会话上右键选择「打开 SFTP」。")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                sessionPinned.toggle()
                workspace.sessionPanelExpanded = sessionPinned
            } label: {
                Label("会话管理器", systemImage: sessionPinned ? "sidebar.left" : "sidebar.squares.left")
            }
            .help(sessionPinned ? "隐藏会话管理器" : "显示会话管理器")

            Button {
                commandPinned.toggle()
                workspace.commandPanelExpanded = commandPinned
            } label: {
                Label("快速命令", systemImage: commandPinned ? "square.grid.2x2.fill" : "square.grid.2x2")
            }
            .help(commandPinned ? "隐藏快速命令" : "显示快速命令")

            Button {
                filePinned.toggle()
                workspace.filePanelExpanded = filePinned
            } label: {
                Label("文件管理器", systemImage: filePinned ? "sidebar.right" : "sidebar.squares.right")
            }
            .help(filePinned ? "隐藏文件管理器" : "显示文件管理器")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.pendingEdit = .newGroup(parent: nil)
            } label: {
                Label("新建分组", systemImage: "folder.badge.plus")
            }
            Button {
                workspace.pendingEdit = .newSession(parent: nil)
            } label: {
                Label("新建会话", systemImage: "plus")
            }
            Button {
                if let node = currentSSHSession, node.isSSH {
                    workspace.openSFTP(node)
                } else {
                    sftpHint = true
                }
            } label: {
                Label("SFTP", systemImage: "externaldrive.connected.to.line.below")
            }
            .help("打开当前会话的 SFTP 选项卡")
            Button(action: workspace.openLocal) {
                Label("本地终端", systemImage: "terminal")
            }
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .help("打开全局设置")
        }
    }

    @ViewBuilder
    private var sessionColumn: some View {
        if sessionPinned {
            sessionPanel
                .frame(width: sessionWidth)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()
            PanelResizeHandle(current: sessionWidth, range: AppTheme.sessionWidthRange) {
                sessionWidth = $0
            } onEnd: {
                storedSessionWidth = sessionWidth
            }
            .zIndex(2)
            Divider()
        }
    }

    private var sessionPanel: some View {
        DockablePanel(
            title: "会话管理器",
            systemImage: "sidebar.left",
            pinned: $sessionPinned,
            expanded: $workspace.sessionPanelExpanded
        ) {
            SessionManagerView(nodes: nodes, workspace: workspace)
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            TabBarView(workspace: workspace)
            Divider()
            ZStack(alignment: .top) {
                workspaceBody
                if let progress = workspace.transfers.zmodem {
                    ZModemBanner(progress: progress) {
                        if let id = workspace.selectedTabID {
                            TerminalRegistry.shared.view(for: id)?.zmodem.cancel()
                        }
                    }
                }
            }
            if commandPinned {
                Divider()
                PanelResizeHandle(vertical: false, inverted: true, current: commandHeight, range: AppTheme.commandHeightRange) {
                    commandHeight = $0
                } onEnd: {
                    storedCommandHeight = commandHeight
                }
                commandPanel
                    .frame(maxWidth: .infinity)
                    .frame(height: clampedCommandHeight)
                    .clipped()
            } else {
                AutoHideStrip(title: "快速命令", systemImage: "square.grid.2x2", axis: .horizontal) {
                    workspace.commandPanelExpanded.toggle()
                }
                if workspace.commandPanelExpanded {
                    commandPanel
                        .frame(maxWidth: .infinity)
                        .frame(height: clampedCommandHeight)
                        .clipped()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var workspaceBody: some View {
        if let tab = workspace.selectedTab {
            tabContent(tab)
                .id(tab.id)
        } else {
            WelcomeView(workspace: workspace)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.kind {
        case .sftp(let sessionID):
            FileManagerView(
                session: workspace.node(in: nodes, id: sessionID),
                transfers: workspace.transfers,
                embeddedInTab: true,
                tabID: tab.id,
                reconnectNonce: workspace.sftpReconnectNonce[tab.id] ?? 0
            )
        case .terminal(let sessionID):
            TerminalSessionView(
                tab: tab,
                session: workspace.node(in: nodes, id: sessionID),
                transfers: workspace.transfers,
                onTitle: { _ in },
                fontSize: settings.terminalFontSize
            )
        case .local:
            TerminalSessionView(
                tab: tab,
                session: nil,
                transfers: workspace.transfers,
                onTitle: { _ in },
                fontSize: settings.terminalFontSize
            )
        }
    }

    @ViewBuilder
    private var fileColumn: some View {
        if filePinned {
            Divider()
            PanelResizeHandle(inverted: true, current: fileWidth, range: AppTheme.fileWidthRange) {
                fileWidth = $0
            } onEnd: {
                storedFileWidth = fileWidth
            }
            .zIndex(2)
            filePanel
                .frame(minWidth: 0)
                .frame(width: fileWidth)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()
        }
    }

    private var filePanel: some View {
        DockablePanel(
            title: "文件管理器",
            systemImage: "folder",
            pinned: $filePinned,
            expanded: $workspace.filePanelExpanded
        ) {
            FileManagerView(session: currentSSHSession, transfers: workspace.transfers)
        }
    }

    private var commandPanel: some View {
        DockablePanel(
            title: "快速命令",
            systemImage: "square.grid.2x2",
            pinned: $commandPinned,
            expanded: $workspace.commandPanelExpanded
        ) {
            QuickCommandView(commands: commands, workspace: workspace, nodes: nodes)
        }
    }

    private var clampedCommandHeight: CGFloat {
        min(max(commandHeight, AppTheme.commandHeightRange.lowerBound), AppTheme.commandHeightRange.upperBound)
    }

    private var currentSSHSession: SessionNode? {
        guard let tab = workspace.selectedTab, let id = tab.sessionID else { return nil }
        return workspace.node(in: nodes, id: id)
    }
}

/// 给主窗口打上 `TermoraX.main`，关闭代理只接管这一扇，避免误伤设置窗口。
private struct WindowIdentifierSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier("TermoraX.main")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.identifier = NSUserInterfaceItemIdentifier("TermoraX.main")
    }
}

