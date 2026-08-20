//
//  SessionManagerView.swift
//  TermoraX
//

import SwiftData
import SwiftUI

struct SessionManagerView: View {
    var nodes: [SessionNode]
    @Bindable var workspace: WorkspaceController

    private var roots: [SessionNode] {
        nodes
            .filter { $0.parent == nil }
            .sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var filtered: [SessionNode] {
        let keyword = workspace.sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return nodes.filter { node in
            !node.isGroup && (
                node.name.localizedCaseInsensitiveContains(keyword) ||
                node.host.localizedCaseInsensitiveContains(keyword) ||
                node.username.localizedCaseInsensitiveContains(keyword)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索会话", text: $workspace.sessionSearch)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)

            List {
                if workspace.sessionSearch.isEmpty {
                    ForEach(roots, id: \.id) { node in
                        SessionOutlineRow(node: node, workspace: workspace)
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView("没有匹配的会话", systemImage: "magnifyingglass")
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered, id: \.id) { node in
                        SessionLeafRow(node: node, workspace: workspace)
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                Button("新建分组") { workspace.pendingEdit = .newGroup(parent: nil) }
                Button("新建会话") { workspace.pendingEdit = .newSession(parent: nil) }
            }

            HStack {
                Button {
                    workspace.pendingEdit = .newGroup(parent: nil)
                } label: {
                    Label("分组", systemImage: "folder.badge.plus")
                }
                Button {
                    workspace.pendingEdit = .newSession(parent: nil)
                } label: {
                    Label("会话", systemImage: "plus")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct SessionOutlineRow: View {
    let node: SessionNode
    var workspace: WorkspaceController

    var body: some View {
        if node.isGroup {
            DisclosureGroup {
                ForEach(node.sortedChildren, id: \.id) { child in
                    SessionOutlineRow(node: child, workspace: workspace)
                }
            } label: {
                SessionLeafRow(node: node, workspace: workspace)
            }
        } else {
            SessionLeafRow(node: node, workspace: workspace)
        }
    }
}

private struct SessionLeafRow: View {
    let node: SessionNode
    var workspace: WorkspaceController

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                Text(node.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: node.isGroup ? "folder.fill" : (node.isLocal ? "laptopcomputer" : "server.rack"))
                .foregroundStyle(node.isGroup ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            workspace.openSSH(node)
        }
        .contextMenu {
            if node.isGroup {
                Button("在此分组下新建会话") { workspace.pendingEdit = .newSession(parent: node) }
                Button("在此分组下新建分组") { workspace.pendingEdit = .newGroup(parent: node) }
            } else {
                Button("连接") { workspace.openSSH(node) }
                if node.isSSH {
                    Button("打开 SFTP") { workspace.openSFTP(node) }
                }
            }
            Button("编辑") { workspace.pendingEdit = .edit(node) }
            Divider()
            Button("删除", role: .destructive) {
                if !node.isGroup {
                    KeychainStore.deletePassword(for: node.id)
                }
                node.modelContext?.delete(node)
            }
        }
    }
}
