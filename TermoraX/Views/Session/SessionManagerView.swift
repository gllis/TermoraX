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

            ScrollView {
                if workspace.sessionSearch.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(roots, id: \.id) { node in
                            SessionOutlineRow(node: node, workspace: workspace)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if filtered.isEmpty {
                    ContentUnavailableView("没有匹配的会话", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered, id: \.id) { node in
                            SessionLeafRow(node: node, workspace: workspace)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
    @Bindable var node: SessionNode
    var workspace: WorkspaceController
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionLeafRow(node: node, workspace: workspace, depth: depth)
            if node.isGroup, node.isExpanded {
                ForEach(node.sortedChildren, id: \.id) { child in
                    SessionOutlineRow(node: child, workspace: workspace, depth: depth + 1)
                }
            }
        }
    }
}

private struct SessionLeafRow: View {
    let node: SessionNode
    var workspace: WorkspaceController
    var depth: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            if node.isGroup {
                Button {
                    node.isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            Image(systemName: node.isGroup ? "folder.fill" : (node.isLocal ? "laptopcomputer" : "server.rack"))
                .font(.system(size: 12))
                .foregroundStyle(node.isGroup ? Color.accentColor : .secondary)
                .frame(width: 14)
            Text(node.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 0)
        .contentShape(Rectangle())
        .help(node.subtitle)
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
                    SecretStore.deletePassword(for: node.id)
                }
                node.modelContext?.delete(node)
            }
        }
    }
}
