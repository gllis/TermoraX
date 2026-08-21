//
//  SeedData.swift
//  TermoraX
//
//  首次启动写入默认分组（生产 / 测试）和几条示例快速命令。
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
            let samples: [(String, String, String, Int)] = [
                ("列出文件", "ls -la", "folder.fill", 0),
                ("磁盘空间", "df -h", "internaldrive.fill", 5),
                ("内存", "free -h || vm_stat", "memorychip", 2),
                ("进程", "top -bn1 | head -n 20", "cpu", 3),
            ]
            for (index, item) in samples.enumerated() {
                context.insert(
                    QuickCommand(
                        name: item.0,
                        command: item.1,
                        sortIndex: index,
                        symbolName: item.2,
                        tintIndex: item.3
                    )
                )
            }
        } else {
            for command in commands where command.symbolName.isEmpty {
                command.symbolName = QuickCommandIcon.suggestedSymbol(for: command.command)
                command.tintIndex = QuickCommandIcon.tintIndex(for: command.name)
            }
        }
        try? context.save()
    }
}
