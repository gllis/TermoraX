//
//  WorkspaceController.swift
//  TermoraX
//

import Foundation
import Observation
import SwiftData
import SwiftUI

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
    }

    func closeOthers(_ id: UUID) {
        let closing = tabs.filter { $0.id != id }
        for tab in closing {
            TerminalRegistry.shared.close(tab.id)
        }
        tabs.removeAll { $0.id != id }
        selectedTabID = id
    }

    func closeAll() {
        for tab in tabs {
            TerminalRegistry.shared.close(tab.id)
        }
        tabs.removeAll()
        selectedTabID = nil
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
    }
}

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
