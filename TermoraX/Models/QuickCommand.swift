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
    var symbolName: String = ""
    var tintIndex: Int = 0

    init(
        name: String,
        command: String,
        sortIndex: Int = 0,
        symbolName: String? = nil,
        tintIndex: Int? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.command = command
        self.sortIndex = sortIndex
        self.createdAt = Date()
        self.symbolName = symbolName ?? QuickCommandIcon.suggestedSymbol(for: command)
        self.tintIndex = tintIndex ?? QuickCommandIcon.tintIndex(for: name)
    }
}
