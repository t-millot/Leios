// Log.swift
// Leios Engine — os.Logger categories.

import Foundation
import os

enum Log {
    static let subsystem = "com.tmillot.Leios"
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let scroll = Logger(subsystem: subsystem, category: "scroll")
    static let buttons = Logger(subsystem: subsystem, category: "buttons")
    static let drag = Logger(subsystem: subsystem, category: "drag")
    static let touch = Logger(subsystem: subsystem, category: "touch")
    static let actions = Logger(subsystem: subsystem, category: "actions")
    static let stats = Logger(subsystem: subsystem, category: "stats")
}
