import Foundation

/// Configuration for a process to run
struct ProcessConfig: Identifiable, Equatable {
  let id: UUID
  var name: String
  var command: String
  var workingDirectory: String
  var shell: String

  init(
    id: UUID = UUID(),
    name: String = "",
    command: String = "",
    workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    shell: String = ProcessConfig.defaultShell
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.workingDirectory = workingDirectory
    self.shell = shell
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
  let config: ProcessConfig
  let panelId: UUID

  @Published var isRunning: Bool = false
  @Published var exitCode: Int32?

  private var panel: Panel?
  private var handle: ProcessHandle?
  private var monitorTask: Task<Void, Never>?

  init(config: ProcessConfig, panel: Panel) {
    self.id = config.id
    self.config = config
    self.panelId = panel.id
    self.panel = panel
  }

  /// Initialize from an existing process handle (for reconnection)
  init(handle: ProcessHandle, panel: Panel, isCurrentlyRunning: Bool) {
    self.id = handle.config.id
    self.config = handle.config
    self.panelId = panel.id
    self.panel = panel
    self.handle = handle
    self.isRunning = isCurrentlyRunning
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
      }
    }
  }

  /// Resume streaming from an existing handle (after app restart)
  func resume(using backend: TmuxBackend, fromBeginning: Bool = false) {
    guard let handle = handle else { return }

    startOutputStreaming(backend: backend, handle: handle, fromBeginning: fromBeginning)
    startExitMonitoring(backend: backend, handle: handle)
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

    // Stop the pipe reader for this process
    if let handle = handle {
      backend.stopOutput(for: handle.id)
    }

    // We don't know the exact exit code from tmux easily,
    // so we'll assume normal exit unless we detect otherwise
    panel?.status = .exitedNormally
    panel?.stoppedAt = Date()
    panel?.appendEvent(.stopped, message: "Process exited")
  }

  /// Terminate the process
  func terminate(using backend: TmuxBackend) {
    guard let handle = handle else { return }
    Task {
      try? await backend.stop(handle: handle)
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
