import SwiftUI
import CoreServices

extension Notification.Name {
  static let menuBarExtraChanged = Notification.Name("menuBarExtraChanged")
}

class SettingsManager: ObservableObject {
  static let shared = SettingsManager()

  @Published var theme: AppTheme = .auto {
    didSet {
      saveSettings()
    }
  }

  @Published var fontSize: CGFloat = 12 {
    didSet {
      saveSettings()
    }
  }

  @Published var maxLineHistory: Int = 10000 {
    didSet {
      saveSettings()
    }
  }

  @Published var autoDirenv: Bool = false {
    didSet {
      saveSettings()
    }
  }

  /// Log retention in seconds. nil means no limit.
  @Published var logRetentionSeconds: Int? = nil {
    didSet {
      saveSettings()
    }
  }

  /// Unit for displaying retention (hours or days) - only for UI purposes
  @Published var logRetentionUnit: RetentionUnit = .days {
    didSet {
      saveSettings()
    }
  }

  /// Show menu bar extra icon
  @Published var showMenuBarExtra: Bool = false {
    didSet {
      saveSettings()
      NotificationCenter.default.post(name: .menuBarExtraChanged, object: nil)
    }
  }

  /// Debounce time for auto-reload (seconds)
  @Published var autoReloadDebounce: TimeInterval = 0.5 {
    didSet {
      saveSettings()
    }
  }

  /// Global include patterns for auto-reload
  @Published var globalAutoReloadIncludes: [String] = [] {
    didSet {
      saveSettings()
    }
  }

  /// Global exclude patterns for auto-reload
  @Published var globalAutoReloadExcludes: [String] = [
    "node_modules/**", "*.log", ".git/**", "*.pyc", "__pycache__/**", "*.o", "*.class", "dist/**",
    "build/**",
  ] {
    didSet {
      saveSettings()
    }
  }

  // MARK: - Auto Restart

  /// Globally enable auto-restart for failed processes
  @Published var autoRestartEnabled: Bool = false {
    didSet { saveSettings() }
  }

  /// Initial delay before restarting (seconds)
  @Published var restartInitialDelay: TimeInterval = 0.5 {
    didSet { saveSettings() }
  }

  /// Maximum delay before restarting (seconds)
  @Published var restartMaxDelay: TimeInterval = 10.0 {
    didSet { saveSettings() }
  }

  /// Time a process must run successfully to reset the backoff counter (seconds)
  @Published var restartResetTime: TimeInterval = 5.0 {
    didSet { saveSettings() }
  }

  init() {
    loadSettings()
  }

  private func loadSettings() {
    if let settings = PersistenceManager.shared.loadSettings() {
      self.theme = settings.theme
      self.fontSize = settings.fontSize > 0 ? settings.fontSize : 12
      self.maxLineHistory = settings.maxLineHistory > 0 ? settings.maxLineHistory : 10000
      self.autoDirenv = settings.autoDirenv
      self.logRetentionSeconds = settings.logRetentionSeconds
      self.logRetentionUnit = settings.logRetentionUnit ?? .days
      self.showMenuBarExtra = settings.showMenuBarExtra ?? false
      self.autoReloadDebounce = settings.autoReloadDebounce ?? 0.5
      if let includes = settings.globalAutoReloadIncludes {
        // Migration: If the user has the legacy default ["**/*"], remove it so it doesn't override per-process includes
        if includes == ["**/*"] {
          self.globalAutoReloadIncludes = []
        } else {
          self.globalAutoReloadIncludes = includes
        }
      }
      if let excludes = settings.globalAutoReloadExcludes {
        self.globalAutoReloadExcludes = excludes
      }
      
      // Auto Restart
      if let enabled = settings.autoRestartEnabled {
        self.autoRestartEnabled = enabled
      }
      if let initial = settings.restartInitialDelay {
        self.restartInitialDelay = initial
      }
      if let max = settings.restartMaxDelay {
        self.restartMaxDelay = max
      }
      if let reset = settings.restartResetTime {
        self.restartResetTime = reset
      }
    }
  }

  private func saveSettings() {
    let settings = GlobalSettings(
      theme: theme,
      fontSize: fontSize,
      maxLineHistory: maxLineHistory,
      autoDirenv: autoDirenv,
      logRetentionSeconds: logRetentionSeconds,
      logRetentionUnit: logRetentionUnit,
      showMenuBarExtra: showMenuBarExtra,
      autoReloadDebounce: autoReloadDebounce,
      globalAutoReloadIncludes: globalAutoReloadIncludes,
      globalAutoReloadExcludes: globalAutoReloadExcludes,
      autoRestartEnabled: autoRestartEnabled,
      restartInitialDelay: restartInitialDelay,
      restartMaxDelay: restartMaxDelay,
      restartResetTime: restartResetTime
    )
    PersistenceManager.shared.saveSettings(settings)
  }

  var colorScheme: ColorScheme? {
    switch theme {
    case .light:
      return .light
    case .dark:
      return .dark
    case .auto:
      return nil
    }
  }
}

// MARK: - Utilities

struct Glob {
    /// Convert a glob pattern to a regex pattern
    static func toRegexPattern(_ glob: String) -> String {
        var pattern = "^"
        let chars = Array(glob)
        var i = 0
        
        while i < chars.count {
            let char = chars[i]
            
            switch char {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // ** matches anything including separators
                    pattern += ".*"
                    i += 1 // Skip second *
                } else {
                    // * matches anything EXCEPT separators
                    pattern += "[^/]*"
                }
            case "?":
                pattern += "[^/]" // Match one non-separator char
            case ".":
                pattern += "\\."
            case "/":
                pattern += "/"
            case "{", "}", "(", ")", "+", "|", "^", "$", "\\":
                pattern += "\\" + String(char)
            case "[":
                // Character class
                pattern += "["
                i += 1
                while i < chars.count && chars[i] != "]" {
                    if chars[i] == "\\" {
                        pattern += "\\"
                        i += 1
                    }
                    pattern += String(chars[i])
                    i += 1
                }
                if i < chars.count {
                    pattern += "]"
                }
            default:
                pattern += String(char)
            }
            i += 1
        }
        
        pattern += "$"
        return pattern
    }
    
    /// Check if a path matches a glob pattern
    static func matches(_ path: String, pattern: String) -> Bool {
        // Optimization: simple equality
        if pattern == path { return true }
        
        let regexPattern = toRegexPattern(pattern)
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
            return false
        }
        
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }
}

class FileMonitor {
    private var stream: FSEventStreamRef?
    private let path: String
    private let latency: TimeInterval
    private let debounceInterval: TimeInterval
    private let callback: ([String]) -> Void
    private let queue = DispatchQueue(label: "com.proceed.filemonitor", qos: .utility)
    
    // Debounce state
    private var debounceTimer: DispatchSourceTimer?
    private var changedPaths: Set<String> = []
    
    init(path: String, latency: TimeInterval = 0.5, debounce: TimeInterval = 0.5, callback: @escaping ([String]) -> Void) {
        self.path = path
        self.latency = latency
        self.debounceInterval = debounce
        self.callback = callback
    }
    
    deinit {
        stop()
    }
    
    func start() {
        print("FileMonitor: Starting watch on \(path)")
        stop() // Ensure stopped
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let pathsToWatch = [path] as CFArray
        
        // kFSEventStreamCreateFlagFileEvents: Fire events for files, not just dirs
        // kFSEventStreamCreateFlagUseCFTypes: Use CF types for paths
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        
        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            let monitor = Unmanaged<FileMonitor>.fromOpaque(clientCallBackInfo!).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            monitor.handleEvents(paths: paths)
        }
        
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(flags)
        ) else {
            print("Failed to create FSEventStream")
            return
        }
        
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }
    
    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceTimer?.cancel()
        debounceTimer = nil
        changedPaths.removeAll()
    }
    
    private func handleEvents(paths: [String]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            for p in paths {
                if p.hasPrefix(self.path) {
                    // Strip prefix to get relative path
                    let prefixLen = self.path.count
                    let relative = String(p.dropFirst(prefixLen))
                    let cleanRelative = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
                    self.changedPaths.insert(cleanRelative)
                }
            }
            
            self.scheduleDebouncedCallback()
        }
    }
    
    private func scheduleDebouncedCallback() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            self?.fireCallback()
        }
        debounceTimer = timer
        timer.resume()
    }
    
    private func fireCallback() {
        guard !changedPaths.isEmpty else { return }
        let paths = Array(changedPaths)
        changedPaths.removeAll()
        
        print("FileMonitor: Firing callback with \(paths.count) paths")
        // Dispatch callback
        callback(paths)
    }
}
