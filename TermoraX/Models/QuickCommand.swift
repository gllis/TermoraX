//
//  QuickCommand.swift
//  TermoraX
//

import Foundation
import SwiftData

@Model
final class QuickCommand {
    var id: UUID
    var name: String
    var command: String
    var sortIndex: Int
    var createdAt: Date

    init(name: String, command: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.command = command
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}
