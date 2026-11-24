//
//  Item.swift
//  Ben
//
//  Created by 王建朝 on 2026/11/24.
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
