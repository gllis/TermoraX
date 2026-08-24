//
//  SessionNode.swift
//  TermoraX
//
//  会话树节点：分组或主机。密码不存在这里，只存 `id`，密文在 SecretStore。
//

import Foundation
import SwiftData

/// SwiftData 模型。分组可嵌套；叶子节点是 SSH 或本地终端。
@Model
final class SessionNode {
    var id: UUID
    var name: String
    var isGroup: Bool
    var sortIndex: Int
    var createdAt: Date

    /// `ssh` or `local`
    var sessionProtocol: String
    var host: String
    var port: Int
    var username: String
    /// `default`, `password`, `key`
    var authMethod: String
    var privateKeyPath: String
    var sftpDefaultPath: String
    var note: String
    var isExpanded: Bool = true

    var parent: SessionNode?
    @Relationship(deleteRule: .cascade, inverse: \SessionNode.parent)
    var children: [SessionNode]

    init(
        name: String,
        isGroup: Bool,
        parent: SessionNode? = nil,
        sortIndex: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.isGroup = isGroup
        self.sortIndex = sortIndex
        self.createdAt = Date()
        self.sessionProtocol = isGroup ? "" : "ssh"
        self.host = ""
        self.port = 22
        self.username = ""
        self.authMethod = "default"
        self.privateKeyPath = ""
        self.sftpDefaultPath = ""
        self.note = ""
        self.isExpanded = true
        self.parent = parent
        self.children = []
    }

    var sortedChildren: [SessionNode] {
        children.sorted {
            if $0.isGroup != $1.isGroup { return $0.isGroup && !$1.isGroup }
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var isSSH: Bool { !isGroup && sessionProtocol == "ssh" }
    var isLocal: Bool { !isGroup && sessionProtocol == "local" }

    /// 在同一父级下复制一份。分组会连同子节点一起复制；密码按新 `id` 写入保险库。
    func cloneInPlace() {
        guard let context = modelContext else { return }
        let siblings: [SessionNode]
        if let parent {
            siblings = parent.children
        } else {
            siblings = ((try? context.fetch(FetchDescriptor<SessionNode>())) ?? []).filter { $0.parent == nil }
        }
        for sibling in siblings where sibling.sortIndex > sortIndex {
            sibling.sortIndex += 1
        }
        _ = cloneTree(
            parent: parent,
            sortIndex: sortIndex + 1,
            name: Self.uniqueCopyName(from: name, among: siblings)
        )
        try? context.save()
    }

    private func cloneTree(parent: SessionNode?, sortIndex: Int, name: String) -> SessionNode {
        let copy = SessionNode(name: name, isGroup: isGroup, parent: parent, sortIndex: sortIndex)
        copy.sessionProtocol = sessionProtocol
        copy.host = host
        copy.port = port
        copy.username = username
        copy.authMethod = authMethod
        copy.privateKeyPath = privateKeyPath
        copy.sftpDefaultPath = sftpDefaultPath
        copy.note = note
        copy.isExpanded = isExpanded
        modelContext?.insert(copy)
        if let password = SecretStore.password(for: id), !password.isEmpty {
            SecretStore.setPassword(password, for: copy.id)
        }
        if isGroup {
            for (index, child) in sortedChildren.enumerated() {
                _ = child.cloneTree(parent: copy, sortIndex: index, name: child.name)
            }
        }
        return copy
    }

    private static func uniqueCopyName(from name: String, among siblings: [SessionNode]) -> String {
        let existing = Set(siblings.map(\.name))
        let base = "\(name) 副本"
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(name) 副本 \(n)") { n += 1 }
        return "\(name) 副本 \(n)"
    }

    /// 鼠标悬停时显示的连接信息；会话列表本身只渲染 `name`。
    var subtitle: String {
        if isGroup { return "" }
        if isLocal { return "本地终端" }
        let user = username.isEmpty ? NSUserName() : username
        return host.isEmpty ? "未配置主机" : "\(user)@\(host):\(port)"
    }
}
