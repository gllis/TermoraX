//
//  WorkspaceController.swift
//  TermoraX
//
//  工作区状态：打开的标签、当前选中项、面板展开，以及活动快照的保存 / 恢复。
//

import Foundation
import Observation
import SwiftData
import SwiftUI

/// 主窗口的运行时状态。不写入 SwiftData；标签列表按设置间隔序列化到 UserDefaults。
@Observable
final class WorkspaceController {
    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var sessionSearch = ""
    var sessionPanelExpanded = false
    var filePanelExpanded = false
    var commandPanelExpanded = false
    var pendingEdit: SessionEditorToken?
    var pendingCommandEdit: QuickCommand?
    var showNewCommand = false
    var sendQuickCommandToAll = false

    let transfers = TransferCenter()

    @ObservationIgnored private var didRestoreActivity = false
    @ObservationIgnored private var saveTimer: Timer?

    var selectedTab: WorkspaceTab? {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs.last
    }

    func open(_ node: SessionNode, asSFTP: Bool = false) {
        if node.isGroup { return }
        if node.isLocal {
            openLocal()
            return
        }
        if asSFTP {
            openSFTP(node)
        } else {
            openSSH(node)
        }
    }

    func openSSH(_ node: SessionNode) {
        guard node.isSSH else {
            if node.isLocal { openLocal() }
            return
        }
        let tab = WorkspaceTab(kind: .terminal(sessionID: node.id), title: node.name)
        append(tab)
    }

    func openSFTP(_ node: SessionNode) {
        guard node.isSSH else { return }
        let tab = WorkspaceTab(kind: .sftp(sessionID: node.id), title: "SFTP · \(node.name)")
        append(tab)
    }

    func openLocal() {
        let count = tabs.filter { $0.kind == .local }.count
        let title = count == 0 ? "本地终端" : "本地终端 \(count + 1)"
        append(WorkspaceTab(kind: .local, title: title))
    }

    func close(_ id: UUID) {
        TerminalRegistry.shared.close(id)
        let index = tabs.firstIndex(where: { $0.id == id })
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            if let index, !tabs.isEmpty {
                let next = tabs[min(index, tabs.count - 1)]
                selectedTabID = next.id
            } else {
                selectedTabID = tabs.last?.id
            }
        }
        persistActivity()
    }

    func closeOthers(_ id: UUID) {
        let closing = tabs.filter { $0.id != id }
        for tab in closing {
            TerminalRegistry.shared.close(tab.id)
        }
        tabs.removeAll { $0.id != id }
        selectedTabID = id
        persistActivity()
    }

    func closeAll() {
        for tab in tabs {
            TerminalRegistry.shared.close(tab.id)
        }
        tabs.removeAll()
        selectedTabID = nil
        persistActivity()
    }

    func sendCommand(_ command: String, allNodes: [SessionNode]) {
        let text = command.hasSuffix("\n") ? command : command + "\n"
        let targets: [WorkspaceTab]
        if sendQuickCommandToAll {
            targets = tabs.filter { !$0.isSFTP }
        } else if let selectedTab, !selectedTab.isSFTP {
            targets = [selectedTab]
        } else {
            targets = []
        }
        for tab in targets {
            TerminalRegistry.shared.send(text, to: tab.id)
        }
        _ = allNodes
    }

    func node(in nodes: [SessionNode], id: UUID) -> SessionNode? {
        nodes.first(where: { $0.id == id })
    }

    private func append(_ tab: WorkspaceTab) {
        tabs.append(tab)
        selectedTabID = tab.id
        persistActivity()
    }

    /// 启动时根据上次快照重开标签。对应会话已被删除的项会跳过。
    func restoreActivity(nodes: [SessionNode]) {
        guard !didRestoreActivity else { return }
        didRestoreActivity = true
        guard let snapshot = AppSettings.shared.loadSnapshot(), !snapshot.tabs.isEmpty else {
            rescheduleActivitySave()
            return
        }
        var restored: [WorkspaceTab] = []
        for item in snapshot.tabs {
            switch item.kind {
            case .local:
                restored.append(WorkspaceTab(id: item.id, kind: .local, title: item.title))
            case .terminal:
                guard let sessionID = item.sessionID, node(in: nodes, id: sessionID)?.isSSH == true else { continue }
                restored.append(WorkspaceTab(id: item.id, kind: .terminal(sessionID: sessionID), title: item.title))
            case .sftp:
                guard let sessionID = item.sessionID, node(in: nodes, id: sessionID)?.isSSH == true else { continue }
                restored.append(WorkspaceTab(id: item.id, kind: .sftp(sessionID: sessionID), title: item.title))
            }
        }
        tabs = restored
        if let selected = snapshot.selectedTabID, restored.contains(where: { $0.id == selected }) {
            selectedTabID = selected
        } else {
            selectedTabID = restored.last?.id
        }
        rescheduleActivitySave()
    }

    /// 把当前标签写入 UserDefaults，不保存 PTY 内容。
    func persistActivity() {
        let snapshot = WorkspaceSnapshot(
            tabs: tabs.map { tab in
                switch tab.kind {
                case .local:
                    return PersistedTab(id: tab.id, kind: .local, sessionID: nil, title: tab.title)
                case .terminal(let sessionID):
                    return PersistedTab(id: tab.id, kind: .terminal, sessionID: sessionID, title: tab.title)
                case .sftp(let sessionID):
                    return PersistedTab(id: tab.id, kind: .sftp, sessionID: sessionID, title: tab.title)
                }
            },
            selectedTabID: selectedTabID
        )
        AppSettings.shared.saveSnapshot(snapshot)
    }

    func rescheduleActivitySave() {
        saveTimer?.invalidate()
        saveTimer = nil
        let interval = AppSettings.shared.activitySaveInterval
        guard interval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            self?.persistActivity()
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }
}

/// 会话编辑 sheet 的来源：新建分组、新建会话或编辑已有节点。
enum SessionEditorToken: Identifiable {
    case newGroup(parent: SessionNode?)
    case newSession(parent: SessionNode?)
    case edit(SessionNode)

    var id: String {
        switch self {
        case .newGroup(let parent):
            return "new-group-\(parent?.id.uuidString ?? "root")"
        case .newSession(let parent):
            return "new-session-\(parent?.id.uuidString ?? "root")"
        case .edit(let node):
            return "edit-\(node.id.uuidString)"
        }
    }
}
