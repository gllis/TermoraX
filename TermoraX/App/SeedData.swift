//
//  SeedData.swift
//  TermoraX
//

import Foundation
import SwiftData

enum SeedData {
    static func populateIfNeeded(in context: ModelContext) {
        let sessions = (try? context.fetch(FetchDescriptor<SessionNode>())) ?? []
        if sessions.isEmpty {
            let production = SessionNode(name: "生产环境", isGroup: true, sortIndex: 0)
            let staging = SessionNode(name: "测试环境", isGroup: true, sortIndex: 1)
            let local = SessionNode(name: "本地终端", isGroup: false, parent: nil, sortIndex: 2)
            local.sessionProtocol = "local"
            local.note = "在本机打开 shell"
            context.insert(production)
            context.insert(staging)
            context.insert(local)
        }

        let commands = (try? context.fetch(FetchDescriptor<QuickCommand>())) ?? []
        if commands.isEmpty {
            let samples: [(String, String)] = [
                ("列出文件", "ls -la"),
                ("磁盘空间", "df -h"),
                ("内存", "free -h || vm_stat"),
                ("进程", "top -bn1 | head -n 20"),
            ]
            for (index, item) in samples.enumerated() {
                context.insert(QuickCommand(name: item.0, command: item.1, sortIndex: index))
            }
        }
        try? context.save()
    }
}
