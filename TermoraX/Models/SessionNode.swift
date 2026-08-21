//
//  SessionNode.swift
//  TermoraX
//

import Foundation
import SwiftData

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

    var subtitle: String {
        if isGroup { return "" }
        if isLocal { return "本地终端" }
        let user = username.isEmpty ? NSUserName() : username
        return host.isEmpty ? "未配置主机" : "\(user)@\(host):\(port)"
    }
}
