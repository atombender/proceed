import Foundation
import CoreGraphics

// MARK: - Global Settings

/// Global app settings
struct GlobalSettings: Codable {
  var theme: AppTheme
  var fontSize: CGFloat
  var maxLineHistory: Int
  var autoDirenv: Bool
  var logRetentionSeconds: Int?  // nil means no limit
  var logRetentionUnit: RetentionUnit?  // for UI display purposes
  var showMenuBarExtra: Bool?
  var autoReloadDebounce: TimeInterval?
  var globalAutoReloadIncludes: [String]?
  var globalAutoReloadExcludes: [String]?

  // Auto Restart
  var autoRestartEnabled: Bool?
  var restartInitialDelay: TimeInterval?
  var restartMaxDelay: TimeInterval?
  var restartResetTime: TimeInterval?

  // HTTP API
  var httpAPIEnabled: Bool?
  var httpAPIPort: UInt16?

  init(
    theme: AppTheme = .auto,
    fontSize: CGFloat = 12,
    maxLineHistory: Int = 10000,
    autoDirenv: Bool = false,
    logRetentionSeconds: Int? = nil,
    logRetentionUnit: RetentionUnit? = nil,
    showMenuBarExtra: Bool? = nil,
    autoReloadDebounce: TimeInterval? = 0.5,
    globalAutoReloadIncludes: [String]? = [],
    globalAutoReloadExcludes: [String]? = [
      "node_modules/**", "*.log", ".git/**", "*.pyc", "__pycache__/**", "*.o", "*.class", "dist/**",
      "build/**",
    ],
    autoRestartEnabled: Bool? = false,
    restartInitialDelay: TimeInterval? = 0.5,
    restartMaxDelay: TimeInterval? = 10.0,
    restartResetTime: TimeInterval? = 5.0,
    httpAPIEnabled: Bool? = true,
    httpAPIPort: UInt16? = Constants.defaultHTTPPort
  ) {
    self.theme = theme
    self.fontSize = fontSize
    self.maxLineHistory = maxLineHistory
    self.autoDirenv = autoDirenv
    self.logRetentionSeconds = logRetentionSeconds
    self.logRetentionUnit = logRetentionUnit
    self.showMenuBarExtra = showMenuBarExtra
    self.autoReloadDebounce = autoReloadDebounce
    self.globalAutoReloadIncludes = globalAutoReloadIncludes
    self.globalAutoReloadExcludes = globalAutoReloadExcludes
    self.autoRestartEnabled = autoRestartEnabled
    self.restartInitialDelay = restartInitialDelay
    self.restartMaxDelay = restartMaxDelay
    self.restartResetTime = restartResetTime
    self.httpAPIEnabled = httpAPIEnabled
    self.httpAPIPort = httpAPIPort
  }
}

// MARK: - Enums

enum AppTheme: String, Codable, CaseIterable, Identifiable {
  case light
  case dark
  case auto

  var id: String { rawValue }
}

enum AutoRestartMode: String, Codable, CaseIterable, Identifiable {
  case auto  // Follow global setting
  case always
  case never

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .auto: return "Auto (Global)"
    case .always: return "Always"
    case .never: return "Never"
    }
  }
}

enum RetentionUnit: String, Codable {
  case hours
  case days
}

// MARK: - Persisted State Types

/// Persisted panel state
struct PanelState: Codable, Identifiable {
  var id: UUID
  var title: String
  var processConfig: ProcessConfigState?
  var status: PanelStatusState
  var handleId: String?  // tmux session ID for reconnection
}

/// Persisted process config
struct ProcessConfigState: Codable {
  var name: String
  var command: String
  var workingDirectory: String
  var shell: String
  var autoReloadEnabled: Bool?
  var autoReloadIncludes: [String]?
  var autoReloadExcludes: [String]?
  var autoRestart: AutoRestartMode?
  var outputExcludeFilters: [String]?
}

/// Persisted panel status
enum PanelStatusState: Codable {
  case running
  case exitedNormally
  case exitedWithError(code: Int32)
}

/// Persisted layout node (mirrors TileNode structure)
indirect enum LayoutNode: Codable {
  case leaf(id: UUID, panelId: UUID)
  case split(
    id: UUID, direction: LayoutDirection, first: LayoutNode, second: LayoutNode, ratio: CGFloat)
}

enum LayoutDirection: String, Codable {
  case horizontal
  case vertical
}
