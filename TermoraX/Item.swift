//
//  Item.swift
//  TermoraX
//
//  Created by liguilong on 2026/8/20.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
