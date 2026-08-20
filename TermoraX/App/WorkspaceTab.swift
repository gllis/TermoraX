//
//  WorkspaceTab.swift
//  TermoraX
//

import Foundation

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
