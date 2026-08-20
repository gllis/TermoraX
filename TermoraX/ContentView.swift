//
//  ContentView.swift
//  TermoraX
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionNode.sortIndex) private var nodes: [SessionNode]
    @Query(sort: \QuickCommand.sortIndex) private var commands: [QuickCommand]
    @State private var workspace = WorkspaceController()

    @AppStorage("sessionPanelPinned") private var sessionPinned = true
    @AppStorage("filePanelPinned") private var filePinned = false
    @AppStorage("commandPanelPinned") private var commandPinned = true
    @AppStorage("sessionPanelWidth") private var sessionWidth = 260.0
    @AppStorage("filePanelWidth") private var fileWidth = 520.0
    @AppStorage("commandPanelHeight") private var commandHeight = 108.0
    @State private var sftpHint = false

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                sessionColumn
                mainColumn
                fileColumn
            }
            if !sessionPinned && workspace.sessionPanelExpanded {
                sessionPanel
                    .frame(width: sessionWidth)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .trailing) { Divider() }
                    .shadow(radius: 18)
                    .padding(.leading, AppTheme.autoHideStrip)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onHover { hovering in
                        if hovering { workspace.sessionPanelExpanded = true }
                        else { collapseSessionSoon() }
                    }
            }
            if !filePinned && workspace.filePanelExpanded {
                HStack {
                    Spacer()
                    filePanel
                        .frame(width: fileWidth)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .leading) { Divider() }
                        .shadow(radius: 18)
                        .padding(.trailing, AppTheme.autoHideStrip)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .onHover { hovering in
                    if hovering { workspace.filePanelExpanded = true }
                    else { collapseFileSoon() }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: workspace.sessionPanelExpanded)
        .animation(.easeInOut(duration: 0.18), value: workspace.filePanelExpanded)
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
        .onAppear {
            SeedData.populateIfNeeded(in: modelContext)
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
            .help(sessionPinned ? "会话管理器已固定，点击改为自动隐藏" : "会话管理器自动隐藏中，点击固定")

            Button {
                commandPinned.toggle()
                workspace.commandPanelExpanded = commandPinned
            } label: {
                Label("快速命令", systemImage: "bolt.horizontal")
            }
            .help(commandPinned ? "快速命令已固定，点击改为自动隐藏" : "快速命令自动隐藏中，点击固定")

            Button {
                filePinned.toggle()
                workspace.filePanelExpanded = filePinned
            } label: {
                Label("文件管理器", systemImage: filePinned ? "sidebar.right" : "sidebar.squares.right")
            }
            .help(filePinned ? "文件管理器已固定，点击改为自动隐藏" : "文件管理器自动隐藏中，点击固定")
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
        }
    }

    @ViewBuilder
    private var sessionColumn: some View {
        if sessionPinned {
            sessionPanel
                .frame(width: sessionWidth)
            PanelResizeHandle(current: sessionWidth, range: AppTheme.sessionWidthRange) { sessionWidth = $0 }
        } else {
            AutoHideStrip(title: "会话管理器", systemImage: "sidebar.left", axis: .vertical) {
                workspace.sessionPanelExpanded = true
            }
            .onHover { hovering in
                if hovering { workspace.sessionPanelExpanded = true }
            }
        }
        Divider()
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
                }
                commandPanel
                    .frame(height: commandHeight)
            } else {
                AutoHideStrip(title: "快速命令", systemImage: "bolt.horizontal", axis: .horizontal) {
                    workspace.commandPanelExpanded.toggle()
                }
                if workspace.commandPanelExpanded {
                    commandPanel
                        .frame(height: commandHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                embeddedInTab: true
            )
        case .terminal(let sessionID):
            TerminalSessionView(
                tab: tab,
                session: workspace.node(in: nodes, id: sessionID),
                transfers: workspace.transfers,
                onTitle: { title in
                    if let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }) {
                        workspace.tabs[index].title = title.isEmpty ? workspace.tabs[index].title : title
                    }
                }
            )
        case .local:
            TerminalSessionView(
                tab: tab,
                session: nil,
                transfers: workspace.transfers,
                onTitle: { title in
                    if let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }) {
                        workspace.tabs[index].title = title.isEmpty ? workspace.tabs[index].title : title
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var fileColumn: some View {
        Divider()
        if filePinned {
            PanelResizeHandle(inverted: true, current: fileWidth, range: AppTheme.fileWidthRange) { fileWidth = $0 }
            filePanel
                .frame(width: fileWidth)
        } else {
            AutoHideStrip(title: "文件管理器", systemImage: "folder", axis: .vertical) {
                workspace.filePanelExpanded = true
            }
            .onHover { hovering in
                if hovering { workspace.filePanelExpanded = true }
            }
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
            systemImage: "bolt.horizontal",
            pinned: $commandPinned,
            expanded: $workspace.commandPanelExpanded,
            height: commandHeight
        ) {
            QuickCommandView(commands: commands, workspace: workspace, nodes: nodes)
        }
    }

    private var currentSSHSession: SessionNode? {
        guard let tab = workspace.selectedTab, let id = tab.sessionID else { return nil }
        return workspace.node(in: nodes, id: id)
    }

    private func collapseSessionSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            if !sessionPinned { workspace.sessionPanelExpanded = false }
        }
    }

    private func collapseFileSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            if !filePinned { workspace.filePanelExpanded = false }
        }
    }
}

