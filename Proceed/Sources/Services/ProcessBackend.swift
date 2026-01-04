import Foundation

/// Handle to a running or reconnectable process
struct ProcessHandle: Identifiable, Equatable {
    let id: String              // Unique identifier for reconnection (e.g., tmux session name)
    let config: ProcessConfig
    let pipePath: URL           // Path to named pipe for output

    static func == (lhs: ProcessHandle, rhs: ProcessHandle) -> Bool {
        lhs.id == rhs.id
    }
}

/// Protocol for process execution backends
/// Implementations manage process lifecycle and output streaming
protocol ProcessBackend {
    /// Start a new process
    /// - Parameter config: Process configuration
    /// - Returns: Handle for the started process
    func start(config: ProcessConfig) async throws -> ProcessHandle

    /// Stop a running process gracefully (SIGTERM)
    /// - Parameter handle: Process handle
    func stop(handle: ProcessHandle) async throws

    /// Kill a process forcefully (SIGKILL)
    /// - Parameter handle: Process handle
    func kill(handle: ProcessHandle) async throws

    /// Check if a process is currently running
    /// - Parameter handle: Process handle
    /// - Returns: true if process is running
    func isRunning(handle: ProcessHandle) async -> Bool

    /// List all processes managed by this backend (running or recently exited)
    /// - Returns: Array of process handles
    func listAll() async throws -> [ProcessHandle]

    /// Reconnect to a previously running process (after app restart)
    /// - Parameter identifier: The process handle ID
    /// - Returns: Handle if process still exists, nil otherwise
    func reconnect(identifier: String) async throws -> ProcessHandle?

    /// Create an async stream of output lines for a process
    /// - Parameters:
    ///   - handle: Process handle
    ///   - fromBeginning: If true, stream from start of log; if false, only new output
    /// - Returns: AsyncStream of output lines
    func outputStream(for handle: ProcessHandle, fromBeginning: Bool) -> AsyncStream<String>

    /// Clean up resources for a process (delete logs, etc.)
    /// - Parameter handle: Process handle
    func cleanup(handle: ProcessHandle) async throws
}

/// Errors that can occur in process backends
enum ProcessBackendError: LocalizedError {
    case startFailed(String)
    case notFound(String)
    case commandFailed(String)
    case tmuxNotInstalled

    var errorDescription: String? {
        switch self {
        case .startFailed(let msg):
            return "Failed to start process: \(msg)"
        case .notFound(let id):
            return "Process not found: \(id)"
        case .commandFailed(let msg):
            return "Command failed: \(msg)"
        case .tmuxNotInstalled:
            return "tmux is not installed. Please install it via Homebrew: brew install tmux"
        }
    }
}
