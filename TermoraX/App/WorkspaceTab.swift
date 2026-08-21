//
//  WorkspaceTab.swift
//  TermoraX
//
//  中间区域的一个标签：SSH 终端、SFTP 或本地 shell。`id` 同时作为 TerminalRegistry 的键。
//

import Foundation

/// 工作区标签。标题使用会话名称，避免被远程 `OSC` 标题（如 `root@host:~`）覆盖。
struct WorkspaceTab: Identifiable, Hashable {
    enum Kind: Hashable {
        case terminal(sessionID: UUID)
        case sftp(sessionID: UUID)
        case local
    }

    let id: UUID
    var kind: Kind
    var title: String

    init(id: UUID = UUID(), kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }

    var sessionID: UUID? {
        switch kind {
        case .terminal(let id), .sftp(let id):
            return id
        case .local:
            return nil
        }
    }

    var isSFTP: Bool {
        if case .sftp = kind { return true }
        return false
    }

    var systemImage: String {
        switch kind {
        case .terminal: return "terminal"
        case .sftp: return "folder"
        case .local: return "laptopcomputer"
        }
    }
}
