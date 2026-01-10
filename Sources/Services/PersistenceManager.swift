import Foundation
import SQLite3

/// Types of log entries
enum LogEntryKind: Int {
  case output = 0  // Normal process output
  case started = 1  // Process started
  case stopped = 2  // Process stopped normally
  case failed = 3  // Process exited with error
  case info = 4  // Informational message
}

/// Manages persistence of app state and process output using SQLite
class PersistenceManager {
  static let shared = PersistenceManager()

  private let fileManager = FileManager.default
  private var db: OpaquePointer?

  /// Serial queue for ALL database operations (SQLite isn't thread-safe by default)
  private let dbQueue = DispatchQueue(label: "com.proceed.db", qos: .utility)

  /// Timer for periodic cleanup
  private var cleanupTimer: DispatchSourceTimer?

  /// Base directory for app state
  private var appSupportDirectory: URL {
    let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    return urls[0].appendingPathComponent("Proceed", isDirectory: true)
  }

  /// Path to SQLite database
  private var databasePath: URL {
    appSupportDirectory.appendingPathComponent("logs.db")
  }

  private init() {
    createDirectoriesIfNeeded()
    openDatabase()
    createTables()
    startCleanupTimer()
  }

  deinit {
    cleanupTimer?.cancel()
    sqlite3_close(db)
  }

  /// Create app directories if they don't exist
  private func createDirectoriesIfNeeded() {
    do {
      try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    } catch {
      print("Error creating app directories: \(error)")
    }
  }

  /// Open SQLite database
  private func openDatabase() {
    let path = databasePath.path
    if sqlite3_open(path, &db) != SQLITE_OK {
      print("Error opening database: \(String(cString: sqlite3_errmsg(db)))")
    }

    // Enable WAL mode for better concurrent performance
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
  }

  /// Create tables if they don't exist
  private func createTables() {
    let sql = """
      CREATE TABLE IF NOT EXISTS log_lines (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          panel_id TEXT NOT NULL,
          text TEXT NOT NULL,
          timestamp REAL NOT NULL,
          kind INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_panel_id ON log_lines(panel_id);
      CREATE INDEX IF NOT EXISTS idx_panel_timestamp ON log_lines(panel_id, timestamp);
      CREATE INDEX IF NOT EXISTS idx_panel_id_desc ON log_lines(panel_id, id DESC);

      CREATE TABLE IF NOT EXISTS run_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          command TEXT NOT NULL,
          working_directory TEXT NOT NULL,
          shell TEXT NOT NULL,
          started_at REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_run_history_started ON run_history(started_at DESC);
      """

    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
      print("Error creating tables: \(String(cString: sqlite3_errmsg(db)))")
    }

    // Migration: add kind column if it doesn't exist
    // SQLite doesn't support IF NOT EXISTS for ALTER TABLE, so we check first
    var stmt: OpaquePointer?
    let checkSql = "SELECT COUNT(*) FROM pragma_table_info('log_lines') WHERE name='kind'"
    if sqlite3_prepare_v2(db, checkSql, -1, &stmt, nil) == SQLITE_OK {
      if sqlite3_step(stmt) == SQLITE_ROW {
        let count = sqlite3_column_int(stmt, 0)
        if count == 0 {
          sqlite3_exec(
            db, "ALTER TABLE log_lines ADD COLUMN kind INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }
      }
    }
    sqlite3_finalize(stmt)
  }

  // MARK: - Log Database

  /// Append a line to a panel's log (async, runs on background queue)
  func appendToLog(
    panelId: UUID, line: String, timestamp: Date = Date(), kind: LogEntryKind = .output
  ) {
    let panelIdStr = panelId.uuidString
    let timestampVal = timestamp.timeIntervalSince1970
    let kindVal = Int32(kind.rawValue)

    dbQueue.async { [weak self] in
      guard let self = self, let db = self.db else { return }

      let sql = "INSERT INTO log_lines (panel_id, text, timestamp, kind) VALUES (?, ?, ?, ?)"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(
          stmt, 1, panelIdStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, line, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 3, timestampVal)
        sqlite3_bind_int(stmt, 4, kindVal)

        if sqlite3_step(stmt) != SQLITE_DONE {
          print("Error inserting log line: \(String(cString: sqlite3_errmsg(db)))")
        }
      }
      sqlite3_finalize(stmt)
    }
  }

  /// Append multiple lines to a panel's log (async, runs on background queue)
  func appendToLog(
    panelId: UUID, lines: [String], timestamps: [Date]? = nil, kind: LogEntryKind = .output
  ) {
    guard !lines.isEmpty else { return }

    let panelIdStr = panelId.uuidString
    let kindVal = Int32(kind.rawValue)
    // Capture timestamps as intervals to avoid Date reference issues
    let timestampVals: [TimeInterval] =
      timestamps?.map { $0.timeIntervalSince1970 }
      ?? Array(repeating: Date().timeIntervalSince1970, count: lines.count)

    dbQueue.async { [weak self] in
      guard let self = self, let db = self.db else { return }

      sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

      let sql = "INSERT INTO log_lines (panel_id, text, timestamp, kind) VALUES (?, ?, ?, ?)"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        for (index, line) in lines.enumerated() {
          sqlite3_bind_text(
            stmt, 1, panelIdStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          sqlite3_bind_text(stmt, 2, line, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          sqlite3_bind_double(stmt, 3, timestampVals[index])
          sqlite3_bind_int(stmt, 4, kindVal)

          if sqlite3_step(stmt) != SQLITE_DONE {
            print("Error inserting log line: \(String(cString: sqlite3_errmsg(db)))")
          }

          sqlite3_reset(stmt)
        }
      }
      sqlite3_finalize(stmt)

      sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }
  }

  /// Read log lines with timestamps for a panel (most recent N lines)
  func readLog(for panelId: UUID, limit: Int = 10000) -> [(
    text: String, timestamp: Date, kind: LogEntryKind
  )] {
    let start = Date()
    return dbQueue.sync { [weak self] () -> [(text: String, timestamp: Date, kind: LogEntryKind)] in
      guard let self = self, let db = self.db else { return [] }

      var results: [(text: String, timestamp: Date, kind: LogEntryKind)] = []

      // Get the most recent lines, but return them in chronological order
      let sql = """
        SELECT text, timestamp, kind FROM (
            SELECT text, timestamp, kind FROM log_lines
            WHERE panel_id = ?
            ORDER BY id DESC
            LIMIT ?
        ) ORDER BY timestamp ASC
        """
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(
          stmt, 1, panelId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
          if let textPtr = sqlite3_column_text(stmt, 0) {
            let text = String(cString: textPtr)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let kindRaw = sqlite3_column_int(stmt, 2)
            let kind = LogEntryKind(rawValue: Int(kindRaw)) ?? .output
            results.append((text: text, timestamp: timestamp, kind: kind))
          }
        }
      }
      sqlite3_finalize(stmt)

      let duration = Date().timeIntervalSince(start)
      if duration > 0.1 {
        print("PersistenceManager: Read \(results.count) lines for \(panelId) in \(String(format: "%.3f", duration))s")
      }

      return results
    }
  }

  /// Read log lines asynchronously using a transient read-only connection
  /// This allows multiple panels to load in parallel, bypassing the serial dbQueue
  func readLogAsync(for panelId: UUID, limit: Int = 10000) async -> [(
    text: String, timestamp: Date, kind: LogEntryKind
  )] {
    let path = databasePath.path
    var localDb: OpaquePointer?

    // Open a new read-only connection for this operation
    if sqlite3_open_v2(path, &localDb, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
      print("Error opening local database connection: \(String(cString: sqlite3_errmsg(localDb)))")
      return []
    }
    defer { sqlite3_close(localDb) }

    // Enable WAL mode implies we can read while writing, but we don't need to set PRAGMA here
    // as it's a property of the database file itself (persistent journal mode).

    var results: [(text: String, timestamp: Date, kind: LogEntryKind)] = []
    let sql = """
      SELECT text, timestamp, kind FROM (
          SELECT text, timestamp, kind FROM log_lines
          WHERE panel_id = ?
          ORDER BY id DESC
          LIMIT ?
      ) ORDER BY timestamp ASC
      """
    var stmt: OpaquePointer?

    if sqlite3_prepare_v2(localDb, sql, -1, &stmt, nil) == SQLITE_OK {
      sqlite3_bind_text(
        stmt, 1, panelId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      sqlite3_bind_int(stmt, 2, Int32(limit))

      while sqlite3_step(stmt) == SQLITE_ROW {
        if let textPtr = sqlite3_column_text(stmt, 0) {
          let text = String(cString: textPtr)
          let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
          let kindRaw = sqlite3_column_int(stmt, 2)
          let kind = LogEntryKind(rawValue: Int(kindRaw)) ?? .output
          results.append((text: text, timestamp: timestamp, kind: kind))
        }
      }
    }
    sqlite3_finalize(stmt)

    return results
  }

  /// Delete all log entries for a panel
  func deleteLog(for panelId: UUID) {
    dbQueue.async { [weak self] in
      guard let self = self, let db = self.db else { return }

      let sql = "DELETE FROM log_lines WHERE panel_id = ?"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(
          stmt, 1, panelId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) != SQLITE_DONE {
          print("Error deleting log: \(String(cString: sqlite3_errmsg(db)))")
        }
      }
      sqlite3_finalize(stmt)
    }
  }

  // MARK: - Run History

  /// A record of a past process run
  struct RunHistoryEntry: Identifiable {
    let id: Int64
    let name: String
    let command: String
    let workingDirectory: String
    let shell: String
    let startedAt: Date

    /// Display name for the entry
    var displayName: String {
      name.isEmpty ? command : name
    }
  }

  /// Record a process run in history
  func recordRun(name: String, command: String, workingDirectory: String, shell: String) {
    dbQueue.async { [weak self] in
      guard let self = self, let db = self.db else { return }

      let sql =
        "INSERT INTO run_history (name, command, working_directory, shell, started_at) VALUES (?, ?, ?, ?, ?)"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, command, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 3, workingDirectory, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, shell, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
          print("Error recording run: \(String(cString: sqlite3_errmsg(db)))")
        }
      }
      sqlite3_finalize(stmt)
    }
  }

  /// Get recent runs (most recent first)
  func getRecentRuns(limit: Int = 10) -> [RunHistoryEntry] {
    dbQueue.sync { [weak self] () -> [RunHistoryEntry] in
      guard let self = self, let db = self.db else { return [] }

      var results: [RunHistoryEntry] = []

      let sql = """
        SELECT id, name, command, working_directory, shell, started_at
        FROM run_history
        ORDER BY started_at DESC
        LIMIT ?
        """
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
          let id = sqlite3_column_int64(stmt, 0)
          let name = String(cString: sqlite3_column_text(stmt, 1))
          let command = String(cString: sqlite3_column_text(stmt, 2))
          let workingDirectory = String(cString: sqlite3_column_text(stmt, 3))
          let shell = String(cString: sqlite3_column_text(stmt, 4))
          let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

          results.append(
            RunHistoryEntry(
              id: id,
              name: name,
              command: command,
              workingDirectory: workingDirectory,
              shell: shell,
              startedAt: startedAt
            ))
        }
      }
      sqlite3_finalize(stmt)

      return results
    }
  }

  // MARK: - State Persistence

  /// Clear all saved state and logs
  func clearAll() {
    try? fileManager.removeItem(at: appSupportDirectory)
    createDirectoriesIfNeeded()
    openDatabase()
    createTables()
  }

  // MARK: - Multi-Window State

  /// Path to multi-window state file
  private var multiWindowStateFilePath: URL {
    appSupportDirectory.appendingPathComponent("windows.json")
  }

  /// Path to settings file
  private var settingsFilePath: URL {
    appSupportDirectory.appendingPathComponent("settings.json")
  }

  /// Save multi-window state
  func saveMultiWindowState(_ state: MultiWindowState) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(state)

      // Write atomically: write to temp file, then rename
      let tempPath = multiWindowStateFilePath.appendingPathExtension("tmp")
      try data.write(to: tempPath)
      _ = try fileManager.replaceItemAt(multiWindowStateFilePath, withItemAt: tempPath)
      print("PersistenceManager: Saved multi-window state to \(multiWindowStateFilePath.path)")
    } catch {
      print("Error saving multi-window state: \(error)")
    }
  }

  /// Load multi-window state
  func loadMultiWindowState() -> MultiWindowState? {
    guard fileManager.fileExists(atPath: multiWindowStateFilePath.path) else {
      return nil
    }

    do {
      let data = try Data(contentsOf: multiWindowStateFilePath)
      let decoder = JSONDecoder()
      let state = try decoder.decode(MultiWindowState.self, from: data)
      print("PersistenceManager: Loaded multi-window state with \(state.windows.count) windows")
      return state
    } catch {
      print("Error loading multi-window state: \(error)")
      return nil
    }
  }

  // MARK: - Global Settings

  /// Save global settings
  func saveSettings(_ settings: GlobalSettings) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(settings)
      try data.write(to: settingsFilePath)
    } catch {
      print("Error saving settings: \(error)")
    }
  }

  /// Load global settings
  func loadSettings() -> GlobalSettings? {
    guard fileManager.fileExists(atPath: settingsFilePath.path) else {
      return nil
    }

    do {
      let data = try Data(contentsOf: settingsFilePath)
      let decoder = JSONDecoder()
      return try decoder.decode(GlobalSettings.self, from: data)
    } catch {
      print("Error loading settings: \(error)")
      return nil
    }
  }

  // MARK: - Log Retention Cleanup

  /// Start periodic cleanup timer (runs every 5 minutes)
  private func startCleanupTimer() {
    let timer = DispatchSource.makeTimerSource(queue: dbQueue)
    timer.schedule(deadline: .now() + 60, repeating: 300)  // Start after 1 min, repeat every 5 min
    timer.setEventHandler { [weak self] in
      self?.performRetentionCleanup()
    }
    cleanupTimer = timer
    timer.resume()
  }

  /// Delete old log entries based on retention setting, in small batches
  private func performRetentionCleanup() {
    // Get current retention setting
    guard let settings = loadSettings(),
      let retentionSeconds = settings.logRetentionSeconds
    else {
      return  // No limit set, skip cleanup
    }

    let cutoffTimestamp = Date().timeIntervalSince1970 - Double(retentionSeconds)
    let batchSize = 1000  // Delete in batches to avoid long locks

    // Delete old entries in batches
    var totalDeleted = 0
    var deletedThisBatch = 0

    repeat {
      deletedThisBatch = deleteOldLogsBatch(before: cutoffTimestamp, limit: batchSize)
      totalDeleted += deletedThisBatch

      // Small delay between batches to let other operations through
      if deletedThisBatch == batchSize {
        Thread.sleep(forTimeInterval: 0.05)  // 50ms pause between batches
      }
    } while deletedThisBatch == batchSize

    if totalDeleted > 0 {
      print("Log retention cleanup: deleted \(totalDeleted) old entries")
    }
  }

  /// Delete a batch of old log entries, returns number deleted
  private func deleteOldLogsBatch(before timestamp: Double, limit: Int) -> Int {
    // Use a subquery to find IDs to delete (more efficient than DELETE with LIMIT on SQLite)
    let sql = """
      DELETE FROM log_lines WHERE id IN (
        SELECT id FROM log_lines WHERE timestamp < ? LIMIT ?
      )
      """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      return 0
    }

    sqlite3_bind_double(stmt, 1, timestamp)
    sqlite3_bind_int(stmt, 2, Int32(limit))

    let result = sqlite3_step(stmt)
    let deleted = result == SQLITE_DONE ? Int(sqlite3_changes(db)) : 0
    sqlite3_finalize(stmt)

    return deleted
  }
}

// MARK: - State Models

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
    httpAPIPort: UInt16? = 9476
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

enum AppTheme: String, Codable, CaseIterable, Identifiable {
  case light
  case dark
  case auto

  var id: String { rawValue }
}

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
