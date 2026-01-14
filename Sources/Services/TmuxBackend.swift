import Foundation

/// Process backend using tmux for process management
/// Processes survive app restarts and can be reconnected
final class TmuxBackend: ProcessBackend {
  /// Prefix for all tmux sessions created by Proceed
  private let sessionPrefix = "proceed-"

  /// Directory for named pipes
  private let pipesDirectory: URL

  /// Directory for process metadata
  private let metadataDirectory: URL

  /// Tracks active pipe readers
  private var pipeReaders: [String: PipeReader] = [:]

  /// Lock for thread-safe access to pipeReaders
  private let lock = NSLock()

  init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let proceedDir = appSupport.appendingPathComponent("Proceed", isDirectory: true)
    self.pipesDirectory = proceedDir.appendingPathComponent("pipes", isDirectory: true)
    self.metadataDirectory = proceedDir.appendingPathComponent("tmux-meta", isDirectory: true)

    // Create directories
    try? FileManager.default.createDirectory(at: pipesDirectory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      at: metadataDirectory, withIntermediateDirectories: true)

    // Clean up orphaned pipe files from previous sessions
    cleanupOrphanedPipes()
  }

  /// Remove pipe files that don't have corresponding active tmux sessions
  private func cleanupOrphanedPipes() {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: pipesDirectory, includingPropertiesForKeys: nil
      )
    else { return }

    // Get list of active tmux sessions
    let activeSessions = Set(listActiveSessions())

    for file in files {
      let filename = file.lastPathComponent
      // Only process our log files (proceed-UUID.log)
      guard filename.hasPrefix(sessionPrefix), filename.hasSuffix(".log") else { continue }

      // Extract session ID from filename
      let sessionId = String(filename.dropLast(4))  // Remove .log

      // If no active session with this ID, delete the file
      if !activeSessions.contains(sessionId) {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  /// List all active tmux sessions with our prefix
  private func listActiveSessions() -> [String] {
    guard tmuxExists() else { return [] }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmuxPath())
    process.arguments = ["list-sessions", "-F", "#{session_name}"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""

      return output.split(separator: "\n")
        .map { String($0) }
        .filter { $0.hasPrefix(sessionPrefix) }
    } catch {
      return []
    }
  }

  // MARK: - ProcessBackend Implementation

  func start(config: ProcessConfig) async throws -> ProcessHandle {
    // Verify tmux is installed
    guard tmuxExists() else {
      throw ProcessBackendError.tmuxNotInstalled
    }

    let sessionId = "\(sessionPrefix)\(config.id.uuidString)"
    let logPath = pipesDirectory.appendingPathComponent("\(sessionId).log")
    let metaPath = metadataDirectory.appendingPathComponent("\(sessionId).json")

    // Remove old log file if exists
    try? FileManager.default.removeItem(at: logPath)

    // Create empty log file
    FileManager.default.createFile(atPath: logPath.path, contents: nil)

    // Save metadata for reconnection
    let metadata = ProcessMetadata(config: config)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let metaData = try encoder.encode(metadata)
    try metaData.write(to: metaPath)

    // Build the command - escape single quotes
    var escapedCommand = config.command.replacingOccurrences(of: "'", with: "'\\''")

    // Check if we should use direnv
    if SettingsManager.shared.autoDirenv {
      let envrcPath = URL(fileURLWithPath: config.workingDirectory).appendingPathComponent(".envrc")
      if FileManager.default.fileExists(atPath: envrcPath.path),
        let commandData = config.command.data(using: .utf8)
      {
        // Use base64 to handle complex commands with shell operators (&&, ||, ;, etc.)
        // This avoids nested quoting issues by piping the decoded command to a shell
        let base64 = commandData.base64EncodedString()
        // echo 'BASE64' | base64 -d | direnv exec . $SHELL
        // The single quotes around base64 need escaping for the outer shell's -c '...'
        escapedCommand = "echo '\\''\(base64)'\\'' | base64 -d | direnv exec . \(config.shell)"
      }
    }

    // Create tmux session running the command directly (avoids shell echo)
    // Use -l for login shell and -i for interactive to load all rc files
    // (.zshrc only loads for interactive shells, which is where nix/direnv often set PATH)
    let shellCommand = "\(config.shell) -l -i -c '\(escapedCommand)'"

    // Build tmux arguments
    // Don't pass environment variables - let the login shell load its own from .zshrc/.bashrc
    let tmuxArgs = [
      "new-session",
      "-d",
      "-s", sessionId,
      "-c", config.workingDirectory,
      "-x", "200",
      "-y", "50",
      shellCommand,
    ]

    let createResult = try await runTmux(tmuxArgs)

    guard createResult.exitCode == 0 else {
      try? FileManager.default.removeItem(at: logPath)
      throw ProcessBackendError.startFailed(createResult.stderr)
    }

    // Set up output piping immediately
    let pipeResult = try await runTmux([
      "pipe-pane",
      "-t", sessionId,
      "cat >> '\(logPath.path)'",
    ])

    if pipeResult.exitCode != 0 {
      _ = try? await runTmux(["kill-session", "-t", sessionId])
      try? FileManager.default.removeItem(at: logPath)
      throw ProcessBackendError.startFailed("Failed to set up output pipe: \(pipeResult.stderr)")
    }

    return ProcessHandle(id: sessionId, config: config, pipePath: logPath)
  }

  func stop(handle: ProcessHandle) async throws {
    // Send Ctrl+C (SIGINT) to the process
    _ = try await runTmux(["send-keys", "-t", handle.id, "C-c"])

    // Give it a moment, then send SIGTERM if still running
    try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s

    if await isRunning(handle: handle) {
      // Send SIGTERM via tmux
      _ = try await runTmux(["send-keys", "-t", handle.id, "C-\\"])
      try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
    }

    // Kill the session to clean up (even if process already exited)
    _ = try? await runTmux(["kill-session", "-t", handle.id])
  }

  func kill(handle: ProcessHandle) async throws {
    // Kill the entire tmux session
    let result = try await runTmux(["kill-session", "-t", handle.id])
    if result.exitCode != 0 && !result.stderr.contains("no server running")
      && !result.stderr.contains("session not found")
    {
      throw ProcessBackendError.commandFailed(result.stderr)
    }
  }

  func isRunning(handle: ProcessHandle) async -> Bool {
    // Check if the pane's process is still running (not just if session exists)
    // #{pane_dead} is "1" if the command has exited, "0" if still running
    // Retry a few times in case tmux is slow to respond (e.g. during app startup)
    for attempt in 0..<3 {
      if attempt > 0 {
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms between retries
      }

      guard
        let result = try? await runTmux([
          "display-message", "-t", handle.id, "-p", "#{pane_dead}",
        ])
      else {
        continue  // Retry on failure
      }

      if result.exitCode == 0 {
        // Got a valid response
        return result.stdout == "0"
      }
      // Non-zero exit code might mean session doesn't exist or tmux error - retry
    }
    return false
  }

  func listAll() async throws -> [ProcessHandle] {
    let result = try await runTmux([
      "list-sessions",
      "-F", "#{session_name}",
    ])

    // No sessions is not an error
    if result.exitCode != 0 {
      if result.stderr.contains("no server running") || result.stderr.contains("no sessions") {
        return []
      }
      throw ProcessBackendError.commandFailed(result.stderr)
    }

    let sessionNames = result.stdout
      .components(separatedBy: "\n")
      .filter { $0.hasPrefix(sessionPrefix) && !$0.isEmpty }

    var handles: [ProcessHandle] = []
    for sessionId in sessionNames {
      if let handle = try? await loadHandle(sessionId: sessionId) {
        handles.append(handle)
      }
    }

    return handles
  }

  func reconnect(identifier: String) async throws -> ProcessHandle? {
    // Check if session exists
    let result = try await runTmux(["has-session", "-t", identifier])
    guard result.exitCode == 0 else {
      return nil
    }

    return try await loadHandle(sessionId: identifier)
  }

  func outputStream(for handle: ProcessHandle, fromBeginning: Bool) -> AsyncStream<String> {
    AsyncStream { continuation in
      self.startPipeReader(
        for: handle.id,
        pipePath: handle.pipePath,
        fromBeginning: fromBeginning,
        continuation: continuation
      )
    }
  }

  /// Start output streaming with a direct callback (simpler than AsyncStream)
  func startOutputCallback(
    for handle: ProcessHandle, fromBeginning: Bool, onLine: @escaping (String) -> Void
  ) {
    let reader = PipeReader(
      path: handle.pipePath, fromBeginning: fromBeginning, onLine: onLine, onLines: nil)

    lock.lock()
    pipeReaders[handle.id] = reader
    lock.unlock()

    reader.start()
  }

  /// Start output streaming with batched callback for better performance with high-volume output
  func startOutputBatchCallback(
    for handle: ProcessHandle, fromBeginning: Bool, onLines: @escaping ([String]) -> Void
  ) {
    let reader = PipeReader(
      path: handle.pipePath, fromBeginning: fromBeginning, onLine: nil, onLines: onLines)

    lock.lock()
    pipeReaders[handle.id] = reader
    lock.unlock()

    reader.start()
  }

  /// Stop output streaming for a handle
  func stopOutput(for handleId: String) {
    stopPipeReader(for: handleId)
  }

  func cleanup(handle: ProcessHandle) async throws {
    // Stop pipe reader (done synchronously)
    stopPipeReader(for: handle.id)

    // Kill session if still running
    if await isRunning(handle: handle) {
      try await kill(handle: handle)
    }

    // Delete pipe and metadata files
    try? FileManager.default.removeItem(at: handle.pipePath)
    let metaPath = metadataDirectory.appendingPathComponent("\(handle.id).json")
    try? FileManager.default.removeItem(at: metaPath)
  }

  // MARK: - Private Helpers

  private func tmuxExists() -> Bool {
    FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux")
      || FileManager.default.fileExists(atPath: "/usr/local/bin/tmux")
      || FileManager.default.fileExists(atPath: "/usr/bin/tmux")
  }

  private func tmuxPath() -> String {
    if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux") {
      return "/opt/homebrew/bin/tmux"
    } else if FileManager.default.fileExists(atPath: "/usr/local/bin/tmux") {
      return "/usr/local/bin/tmux"
    } else {
      return "/usr/bin/tmux"
    }
  }

  private struct TmuxResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
  }

  private func runTmux(_ arguments: [String]) async throws -> TmuxResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: tmuxPath())
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    // Inherit current process environment (don't use cached ShellEnvironment)

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return TmuxResult(
      stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? "",
      stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? "",
      exitCode: process.terminationStatus
    )
  }

  private func loadHandle(sessionId: String) async throws -> ProcessHandle? {
    let metaPath = metadataDirectory.appendingPathComponent("\(sessionId).json")
    let logPath = pipesDirectory.appendingPathComponent("\(sessionId).log")

    guard FileManager.default.fileExists(atPath: metaPath.path) else {
      return nil
    }

    let data = try Data(contentsOf: metaPath)
    let metadata = try JSONDecoder().decode(ProcessMetadata.self, from: data)

    // Ensure log file exists for reconnection
    if !FileManager.default.fileExists(atPath: logPath.path) {
      // Create the log file
      FileManager.default.createFile(atPath: logPath.path, contents: nil)

      // Re-establish pipe-pane
      _ = try? await runTmux([
        "pipe-pane",
        "-t", sessionId,
        "cat >> '\(logPath.path)'",
      ])
    }

    return ProcessHandle(
      id: sessionId,
      config: metadata.config,
      pipePath: logPath
    )
  }

  private func startPipeReader(
    for sessionId: String,
    pipePath: URL,
    fromBeginning: Bool,
    continuation: AsyncStream<String>.Continuation
  ) {
    let reader = PipeReader(
      path: pipePath, fromBeginning: fromBeginning,
      onLine: { line in
        continuation.yield(line)
      }, onLines: nil)

    lock.lock()
    pipeReaders[sessionId] = reader
    lock.unlock()

    continuation.onTermination = { [weak self] _ in
      self?.stopPipeReader(for: sessionId)
    }

    // Start reader on a background queue to avoid blocking AsyncStream initialization
    DispatchQueue.global(qos: .userInitiated).async {
      reader.start()
    }
  }

  private func stopPipeReader(for sessionId: String) {
    lock.lock()
    pipeReaders[sessionId]?.stop()
    pipeReaders.removeValue(forKey: sessionId)
    lock.unlock()
  }
}

// MARK: - Supporting Types

/// Metadata saved alongside process for reconnection
private struct ProcessMetadata: Codable {
  let config: ProcessConfig
}

/// Make ProcessConfig Codable for metadata storage
extension ProcessConfig: Codable {
  enum CodingKeys: String, CodingKey {
    case id, name, command, workingDirectory, shell
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    let name = try container.decode(String.self, forKey: .name)
    let command = try container.decode(String.self, forKey: .command)
    let workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    let shell = try container.decode(String.self, forKey: .shell)
    self.init(
      id: id, name: name, command: command, workingDirectory: workingDirectory, shell: shell)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(command, forKey: .command)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    try container.encode(shell, forKey: .shell)
  }
}

/// Monitors a log file for new content (like tail -f)
private class PipeReader {
  private let path: URL
  private let fromBeginning: Bool
  private let onLine: ((String) -> Void)?
  private let onLines: (([String]) -> Void)?
  private var fileHandle: FileHandle?
  private var timer: DispatchSourceTimer?
  private var fileSource: DispatchSourceFileSystemObject?
  private var dataBuffer = Data()
  private var stopped = false
  private let readQueue = DispatchQueue(label: "com.proceed.pipereader", qos: .userInitiated)
  private let lock = NSLock()

  private static let lineFeed: UInt8 = 0x0A  // \n
  private static let carriageReturn: UInt8 = 0x0D  // \r

  init(path: URL, fromBeginning: Bool, onLine: ((String) -> Void)?, onLines: (([String]) -> Void)?)
  {
    self.path = path
    self.fromBeginning = fromBeginning
    self.onLine = onLine
    self.onLines = onLines
  }

  func start() {
    guard let handle = try? FileHandle(forReadingFrom: path) else {
      return
    }

    lock.lock()
    self.fileHandle = handle
    lock.unlock()

    if fromBeginning {
      // Read existing content first
      readNewContent()
    } else {
      // Start from end of file (only new content)
      handle.seekToEndOfFile()
    }

    // Set up file system monitoring as primary mechanism
    // This is event-driven and only fires when the file is modified
    let fd = open(path.path, O_EVTONLY)
    if fd >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend],
        queue: readQueue
      )
      source.setEventHandler { [weak self] in
        self?.readNewContent()
      }
      source.setCancelHandler {
        close(fd)
      }
      self.fileSource = source
      source.resume()
    }

    // Backup timer at 1 second rate in case file system events are missed
    // This is much less aggressive than the previous 50ms polling
    let timer = DispatchSource.makeTimerSource(queue: readQueue)
    timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
    timer.setEventHandler { [weak self] in
      self?.readNewContent()
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    lock.lock()
    stopped = true
    let handle = fileHandle
    fileHandle = nil
    lock.unlock()

    timer?.cancel()
    timer = nil
    fileSource?.cancel()
    fileSource = nil
    try? handle?.close()
  }

  private func readNewContent() {
    lock.lock()
    guard !stopped, let handle = fileHandle else {
      lock.unlock()
      return
    }
    lock.unlock()

    // Use read(upToCount:) which throws Swift errors we can catch
    let data: Data?
    do {
      data = try handle.read(upToCount: 65536)
    } catch {
      // File handle was closed or became invalid - just return silently
      return
    }

    guard let data = data, !data.isEmpty else { return }

    dataBuffer.append(data)

    // Collect all complete lines in this batch
    var batchedLines: [String] = []

    // Process complete lines by finding lineFeed bytes directly
    while let lfIndex = dataBuffer.firstIndex(of: PipeReader.lineFeed) {
      var lineEnd = lfIndex
      // Check for \r\n (strip the \r)
      if lineEnd > dataBuffer.startIndex
        && dataBuffer[dataBuffer.index(before: lineEnd)] == PipeReader.carriageReturn
      {
        lineEnd = dataBuffer.index(before: lineEnd)
      }

      let lineData = dataBuffer[dataBuffer.startIndex..<lineEnd]
      if let lineString = String(data: lineData, encoding: .utf8) {
        if onLines != nil {
          batchedLines.append(lineString)
        } else {
          onLine?(lineString)
        }
      }

      // Remove processed data including the lineFeed
      dataBuffer.removeSubrange(dataBuffer.startIndex...lfIndex)
    }

    // Send batched lines if using batch callback
    if !batchedLines.isEmpty {
      onLines?(batchedLines)
    }
  }
}
