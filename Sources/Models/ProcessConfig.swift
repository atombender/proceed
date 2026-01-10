import Foundation

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

/// Configuration for a process to run
struct ProcessConfig: Identifiable, Equatable {
  let id: UUID
  var name: String
  var command: String
  var workingDirectory: String
  var shell: String
  var autoReloadEnabled: Bool
  var autoReloadIncludes: [String]
  var autoReloadExcludes: [String]
  var autoRestart: AutoRestartMode

  init(
    id: UUID = UUID(),
    name: String = "",
    command: String = "",
    workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    shell: String = ProcessConfig.defaultShell,
    autoReloadEnabled: Bool = false,
    autoReloadIncludes: [String] = [],
    autoReloadExcludes: [String] = [],
    autoRestart: AutoRestartMode = .auto
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.workingDirectory = workingDirectory
    self.shell = shell
    self.autoReloadEnabled = autoReloadEnabled
    self.autoReloadIncludes = autoReloadIncludes
    self.autoReloadExcludes = autoReloadExcludes
    self.autoRestart = autoRestart
  }

  /// Display name for the panel title bar
  var displayName: String {
    if !name.isEmpty {
      return name
    }
    // Use first component of command as fallback
    let firstWord = command.split(separator: " ").first.map(String.init) ?? "Process"
    return firstWord
  }

  /// Get the user's default shell from environment
  static var defaultShell: String {
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }
}

/// Represents a running or completed process managed by a backend
class RunningProcess: ObservableObject, Identifiable {
  let id: UUID
  var config: ProcessConfig
  let panelId: UUID

  @Published var isRunning: Bool = false
  @Published var exitCode: Int32?

  private var panel: Panel?
  private var handle: ProcessHandle?
  private var monitorTask: Task<Void, Never>?
  
  // Auto-reload support
  private var fileMonitor: FileMonitor?
  var onReloadRequest: (() -> Void)?
  
  // Auto-restart support
  private var restartAttempts: Int = 0
  private var resetBackoffTask: Task<Void, Never>?

  init(config: ProcessConfig, panel: Panel, onReloadRequest: (() -> Void)? = nil) {
    self.id = config.id
    self.config = config
    self.panelId = panel.id
    self.panel = panel
    self.onReloadRequest = onReloadRequest
  }

  /// Initialize from an existing process handle (for reconnection)
  init(handle: ProcessHandle, panel: Panel, isCurrentlyRunning: Bool, onReloadRequest: (() -> Void)? = nil) {
    self.id = handle.config.id
    self.config = handle.config
    self.panelId = panel.id
    self.panel = panel
    self.handle = handle
    self.isRunning = isCurrentlyRunning
    self.onReloadRequest = onReloadRequest
  }
  
  /// Update configuration dynamically
  func updateConfig(_ newConfig: ProcessConfig) {
    let oldConfig = self.config
    self.config = newConfig
    
    // Check if auto-reload settings changed
    let autoReloadChanged = oldConfig.autoReloadEnabled != newConfig.autoReloadEnabled ||
                            oldConfig.autoReloadIncludes != newConfig.autoReloadIncludes ||
                            oldConfig.autoReloadExcludes != newConfig.autoReloadExcludes
    
    if autoReloadChanged && isRunning {
      // Restart monitoring with new settings
      fileMonitor?.stop()
      fileMonitor = nil
      
      if newConfig.autoReloadEnabled {
        startFileMonitoring()
      }
    }
  }

  /// Start the process using the backend
  func start(using backend: TmuxBackend) {
    Task {
      do {
        let handle = try await backend.start(config: config)
        self.handle = handle

        await MainActor.run {
          self.isRunning = true
          self.panel?.status = .running
          self.panel?.tmuxHandleId = handle.id
          self.panel?.startedAt = Date()
          self.panel?.stoppedAt = nil
          self.panel?.appendEvent(.started, message: "Started: \(self.config.command)")
          
          // Start file monitoring if enabled
          if self.config.autoReloadEnabled {
            self.startFileMonitoring()
          }
        }
        
        // Schedule task to reset restart attempts after success duration
        resetBackoffTask?.cancel()
        let resetTime = SettingsManager.shared.restartResetTime
        resetBackoffTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(resetTime * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run {
                    if self.isRunning {
                        self.restartAttempts = 0
                    }
                }
            }
        }

        // Start streaming output
        startOutputStreaming(backend: backend, handle: handle, fromBeginning: true)

        // Start monitoring for process exit
        startExitMonitoring(backend: backend, handle: handle)

      } catch {
        await MainActor.run {
          self.isRunning = false
          self.panel?.status = .exitedWithError(code: -1)
          self.panel?.appendEvent(
            .failed, message: "Failed to start: \(error.localizedDescription)")
        }
        // Even if start failed, we might want to retry if configured?
        // Usually "Failed to start" means executable not found etc., retrying might be pointless loop.
        // But for "startup failed after a reload", we DO want to retry.
        handleStartFailure()
      }
    }
  }
  
  private func handleStartFailure() {
      // Reuse termination logic to trigger restart if appropriate
      // We pass a dummy 'backend' reference isn't really needed for logic check, 
      // but handleTermination expects it. However, handleTermination cleans up backend resources.
      // Here we failed to start, so no handle to clean.
      // We should extract the restart logic.
      attemptAutoRestart()
  }

  /// Resume streaming from an existing handle (after app restart)
  func resume(using backend: TmuxBackend, fromBeginning: Bool = false) {
    guard let handle = handle else { return }

    startOutputStreaming(backend: backend, handle: handle, fromBeginning: fromBeginning)
    startExitMonitoring(backend: backend, handle: handle)
    
    // Start file monitoring if enabled (and process is running)
    if isRunning && config.autoReloadEnabled {
      startFileMonitoring()
    }
  }

  private func startOutputStreaming(
    backend: TmuxBackend, handle: ProcessHandle, fromBeginning: Bool
  ) {
    // Use batched callback for better performance with high-volume output
    backend.startOutputBatchCallback(for: handle, fromBeginning: fromBeginning) {
      [weak self] lines in
      guard let self = self else { return }
      DispatchQueue.main.async {
        self.panel?.appendLines(lines)
      }
    }
  }
  
  private func startFileMonitoring() {
    let debounce = SettingsManager.shared.autoReloadDebounce
    let globalIncludes = SettingsManager.shared.globalAutoReloadIncludes
    let globalExcludes = SettingsManager.shared.globalAutoReloadExcludes
    
    // Combine patterns
    let includes = globalIncludes + config.autoReloadIncludes
    let excludes = globalExcludes + config.autoReloadExcludes
    
    // Defaults if empty (though global defaults should handle this)
    let effectiveIncludes = includes.isEmpty ? ["**/*"] : includes
    
    print("RunningProcess: Starting file monitoring for \(config.workingDirectory)")
    print("  Includes: \(effectiveIncludes)")
    print("  Excludes: \(excludes)")
    
    fileMonitor = FileMonitor(
        path: config.workingDirectory,
        debounce: debounce
    ) { [weak self] changedPaths in
        guard let self = self else { return }
        
        // Check if any changed path matches criteria
        for path in changedPaths {
            // Check excludes first
            let isExcluded = excludes.contains { Glob.matches(path, pattern: $0) }
            if isExcluded { continue }
            
            // Check includes
            let isIncluded = effectiveIncludes.contains { Glob.matches(path, pattern: $0) }
            if isIncluded {
                print("Auto-reload triggered by change in: \(path)")
                DispatchQueue.main.async {
                    self.panel?.appendEvent(.info, message: "File changed: \(path). Reloading...")
                    self.onReloadRequest?()
                }
                return // Reload once
            }
        }
    }
    
    fileMonitor?.start()
  }

  private func startExitMonitoring(backend: TmuxBackend, handle: ProcessHandle) {
    monitorTask?.cancel()
    monitorTask = Task {
      // Poll for process exit
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s

        let stillRunning = await backend.isRunning(handle: handle)
        if !stillRunning {
          // Clean up the dead tmux session
          try? await backend.kill(handle: handle)

          await MainActor.run {
            self.handleTermination(backend: backend)
          }
          break
        }
      }
    }
  }

  /// Handle process termination
  private func handleTermination(backend: TmuxBackend) {
    self.isRunning = false
    monitorTask?.cancel()
    fileMonitor?.stop()
    fileMonitor = nil
    resetBackoffTask?.cancel() // Process died, don't reset attempts yet

    // Stop the pipe reader for this process
    if let handle = handle {
      backend.stopOutput(for: handle.id)
    }

    // We don't know the exact exit code from tmux easily,
    // so we'll assume normal exit unless we detect otherwise
    panel?.status = .exitedNormally
    panel?.stoppedAt = Date()
    panel?.appendEvent(.stopped, message: "Process exited")
    
    attemptAutoRestart()
  }
  
  private func attemptAutoRestart() {
    let settings = SettingsManager.shared
    let shouldRestart: Bool
    switch config.autoRestart {
    case .always: shouldRestart = true
    case .never: shouldRestart = false
    case .auto: shouldRestart = settings.autoRestartEnabled
    }
    
    if shouldRestart {
        // Calculate delay
        let initial = settings.restartInitialDelay
        let maxDelay = settings.restartMaxDelay
        let delay = min(initial * pow(2.0, Double(restartAttempts)), maxDelay)
        let targetTime = Date().addingTimeInterval(delay)
        
        print("RunningProcess: Auto-restarting in \(delay)s (attempt \(restartAttempts + 1))")
        
        // Update panel status to show countdown
        DispatchQueue.main.async {
            self.panel?.status = .restarting(target: targetTime)
        }
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                // Check if still in restarting state (user didn't stop it manually)
                if case .restarting = self.panel?.status {
                    self.restartAttempts += 1
                    self.onReloadRequest?()
                }
            }
        }
    }
  }

  /// Terminate the process
  func terminate(using backend: TmuxBackend) {
    guard let handle = handle else { return }

    // Stop monitoring immediately to prevent further reload triggers during shutdown
    fileMonitor?.stop()
    fileMonitor = nil
    resetBackoffTask?.cancel()

    Task {
      try? await backend.stop(handle: handle)

      // Poll to verify the process actually stopped (max 5 seconds)
      var stopped = false
      for _ in 0..<50 {
        if await !backend.isRunning(handle: handle) {
          stopped = true
          break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
      }

      // Only update status if actually stopped
      if stopped {
        await MainActor.run {
          self.isRunning = false
          self.panel?.status = .exitedNormally
          self.panel?.stoppedAt = Date()
          if self.panel?.lines.last?.kind != .stopped {
              self.panel?.appendEvent(.stopped, message: "Process stopped")
          }
        }
      }
    }
  }

  /// Kill the process forcefully
  func kill(using backend: TmuxBackend) {
    guard let handle = handle else { return }
    Task {
      try? await backend.kill(handle: handle)
    }
  }

  /// Clean up all resources
  func cleanup(using backend: TmuxBackend) {
    monitorTask?.cancel()
    fileMonitor?.stop()
    fileMonitor = nil
    guard let handle = handle else { return }
    Task {
      try? await backend.cleanup(handle: handle)
    }
  }

  /// Get the process handle ID for persistence
  var handleId: String? {
    handle?.id
  }
}
