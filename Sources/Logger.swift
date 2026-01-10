import Foundation
import os.log

/// Centralized logging utility using os.log for structured logging
enum Logger {
  private static let subsystem = "com.proceed"

  static let httpServer = OSLog(subsystem: subsystem, category: "httpserver")
  static let persistence = OSLog(subsystem: subsystem, category: "persistence")
  static let settings = OSLog(subsystem: subsystem, category: "settings")
  static let windowManager = OSLog(subsystem: subsystem, category: "windowmanager")
  static let process = OSLog(subsystem: subsystem, category: "process")
  static let tilingState = OSLog(subsystem: subsystem, category: "tilingstate")
  static let ui = OSLog(subsystem: subsystem, category: "ui")
}
