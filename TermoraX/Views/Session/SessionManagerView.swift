//
//  SessionManagerView.swift
//  TermoraX
//
//  左侧会话树。扁平 LazyVStack，折叠状态先改内存再延迟写入 SwiftData，避免整树卡顿。
//

import SwiftData
import SwiftUI

struct SessionManagerView: View {
    var nodes: [SessionNode]
    @Bindable var workspace: WorkspaceController

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
                LazyVStack(alignment: .leading, spacing: 1) {
                    if workspace.sessionSearch.isEmpty {
                        ForEach(visibleRows) { row in
                            SessionRowView(node: row.node, depth: row.depth, workspace: workspace)
                        }
                    } else if filtered.isEmpty {
                        ContentUnavailableView("没有匹配的会话", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(filtered, id: \.id) { node in
                            SessionRowView(node: node, depth: 0, workspace: workspace)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transaction { $0.animation = nil }
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
        .onAppear {
            workspace.seedCollapsedGroupsIfNeeded(from: nodes)
        }
        .onChange(of: workspace.selectedTabID) { _, _ in
            if let sessionID = workspace.selectedTab?.sessionID {
                workspace.selectedSessionID = sessionID
            }
        }
    }

    private var roots: [SessionNode] {
        nodes
            .filter { $0.parent == nil }
            .sorted(by: Self.compare)
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

    private var visibleRows: [SessionRowItem] {
        var rows: [SessionRowItem] = []
        func append(_ node: SessionNode, depth: Int) {
            rows.append(SessionRowItem(node: node, depth: depth))
            guard node.isGroup, workspace.isGroupExpanded(node) else { return }
            for child in node.sortedChildren {
                append(child, depth: depth + 1)
            }
        }
        for root in roots {
            append(root, depth: 0)
        }
        return rows
    }

    private static func compare(_ lhs: SessionNode, _ rhs: SessionNode) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct SessionRowItem: Identifiable {
    var id: UUID { node.id }
    let node: SessionNode
    let depth: Int
}

private struct SessionRowView: View {
    let node: SessionNode
    var depth: Int
    @Bindable var workspace: WorkspaceController

    private var isSelected: Bool { workspace.selectedSessionID == node.id }
    private var isConnected: Bool { !node.isGroup && workspace.connectedSessionIDs.contains(node.id) }
    private var isExpanded: Bool { workspace.isGroupExpanded(node) }
    private var accent: Color { .accentColor }
    private var iconName: String {
        if node.isGroup { return "folder.fill" }
        if node.isLocal { return "laptopcomputer" }
        return "server.rack"
    }
    private var iconColor: Color {
        if isConnected { return accent }
        if node.isGroup { return accent }
        return .secondary
    }
    private var titleColor: Color {
        isConnected ? accent : .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            if node.isGroup {
                Button {
                    workspace.selectSession(node)
                    workspace.toggleGroupExpanded(node)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(node.name)
                .foregroundStyle(titleColor)
                .fontWeight(isConnected ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? accent.opacity(0.18) : Color.clear)
        }
        .contentShape(Rectangle())
        .help(node.subtitle)
        .onTapGesture(count: 2) {
            if node.isGroup {
                workspace.toggleGroupExpanded(node)
            } else {
                workspace.openSSH(node)
            }
        }
        .onTapGesture {
            workspace.selectSession(node)
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
            Button("克隆") { node.cloneInPlace() }
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
