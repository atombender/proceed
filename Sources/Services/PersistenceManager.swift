import Foundation
import SQLite3
import os.log

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
  private var db: OpaquePointer?  // Logs database (disposable)
  private var stateDb: OpaquePointer?  // State database (windows, panels - important)

  /// Serial queue for ALL database operations (SQLite isn't thread-safe by default)
  private let dbQueue = DispatchQueue(label: "com.proceed.db", qos: .utility)

  /// Timer for periodic cleanup
  private var cleanupTimer: DispatchSourceTimer?

  /// Base directory for app state
  private var appSupportDirectory: URL {
    let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    return urls[0].appendingPathComponent("Proceed", isDirectory: true)
  }

  /// Path to logs database (can be deleted without losing window state)
  private var logsDatabasePath: URL {
    appSupportDirectory.appendingPathComponent("logs.db")
  }

  /// Path to state database (windows, panels - should not be deleted)
  private var stateDatabasePath: URL {
    appSupportDirectory.appendingPathComponent("state.db")
  }

  private init() {
    createDirectoriesIfNeeded()
    openDatabases()
    createTables()
    startCleanupTimer()
  }

  deinit {
    cleanupTimer?.cancel()
    sqlite3_close(db)
    sqlite3_close(stateDb)
  }

  /// Create app directories if they don't exist
  private func createDirectoriesIfNeeded() {
    do {
      try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    } catch {
      os_log(
        "Error creating app directories: %{public}@", log: Logger.persistence, type: .error,
        error.localizedDescription)
    }
  }

  /// Open SQLite databases
  private func openDatabases() {
    // Open logs database
    let logsPath = logsDatabasePath.path
    if sqlite3_open(logsPath, &db) != SQLITE_OK {
      os_log(
        "Error opening logs database: %{public}@", log: Logger.persistence, type: .error,
        String(cString: sqlite3_errmsg(db)))
    }
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)

    // Open state database
    let statePath = stateDatabasePath.path
    if sqlite3_open(statePath, &stateDb) != SQLITE_OK {
      os_log(
        "Error opening state database: %{public}@", log: Logger.persistence, type: .error,
        String(cString: sqlite3_errmsg(stateDb)))
    }
    sqlite3_exec(stateDb, "PRAGMA journal_mode=WAL", nil, nil, nil)
    sqlite3_exec(stateDb, "PRAGMA foreign_keys=ON", nil, nil, nil)
  }

  /// Create tables if they don't exist
  private func createTables() {
    // Logs database tables (disposable)
    let logsSql = """
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

    if sqlite3_exec(db, logsSql, nil, nil, nil) != SQLITE_OK {
      os_log(
        "Error creating logs tables: %{public}@", log: Logger.persistence, type: .error,
        String(cString: sqlite3_errmsg(db)))
    }

    // Migration: add kind column if it doesn't exist
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

    // Migration: add auto-reload and filter columns to run_history if they don't exist
    let checkRunHistorySql =
      "SELECT COUNT(*) FROM pragma_table_info('run_history') WHERE name='auto_reload_enabled'"
    stmt = nil
    if sqlite3_prepare_v2(db, checkRunHistorySql, -1, &stmt, nil) == SQLITE_OK {
      if sqlite3_step(stmt) == SQLITE_ROW {
        let count = sqlite3_column_int(stmt, 0)
        if count == 0 {
          // Add all new columns for process config
          sqlite3_exec(
            db,
            """
            ALTER TABLE run_history ADD COLUMN auto_reload_enabled INTEGER NOT NULL DEFAULT 0;
            """, nil, nil, nil)
          sqlite3_exec(
            db,
            """
            ALTER TABLE run_history ADD COLUMN auto_reload_includes TEXT NOT NULL DEFAULT '[]';
            """, nil, nil, nil)
          sqlite3_exec(
            db,
            """
            ALTER TABLE run_history ADD COLUMN auto_reload_excludes TEXT NOT NULL DEFAULT '[]';
            """, nil, nil, nil)
          sqlite3_exec(
            db,
            """
            ALTER TABLE run_history ADD COLUMN output_exclude_filters TEXT NOT NULL DEFAULT '[]';
            """, nil, nil, nil)
          sqlite3_exec(
            db,
            """
            ALTER TABLE run_history ADD COLUMN highlight_patterns TEXT NOT NULL DEFAULT '[]';
            """, nil, nil, nil)
        }
      }
    }
    sqlite3_finalize(stmt)

    // State database tables (important - should not be deleted)
    let stateSql = """
      CREATE TABLE IF NOT EXISTS windows (
          id TEXT PRIMARY KEY,
          last_working_directory TEXT NOT NULL,
          last_command TEXT,
          frame_x REAL,
          frame_y REAL,
          frame_width REAL,
          frame_height REAL,
          layout_json TEXT,
          updated_at REAL NOT NULL
      );

      CREATE TABLE IF NOT EXISTS panels (
          id TEXT PRIMARY KEY,
          window_id TEXT NOT NULL,
          title TEXT NOT NULL,
          handle_id TEXT,
          status_json TEXT NOT NULL,
          config_json TEXT,
          position INTEGER NOT NULL,
          is_minimized INTEGER NOT NULL DEFAULT 0,
          remembered_ratio REAL,
          FOREIGN KEY (window_id) REFERENCES windows(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_panels_window ON panels(window_id);
      """

    if sqlite3_exec(stateDb, stateSql, nil, nil, nil) != SQLITE_OK {
      os_log(
        "Error creating state tables: %{public}@", log: Logger.persistence, type: .error,
        String(cString: sqlite3_errmsg(stateDb)))
    }

    // Migration: add is_minimized and remembered_ratio columns if they don't exist
    let checkMinimizedSql =
      "SELECT COUNT(*) FROM pragma_table_info('panels') WHERE name='is_minimized'"
    var stateStmt: OpaquePointer?
    if sqlite3_prepare_v2(stateDb, checkMinimizedSql, -1, &stateStmt, nil) == SQLITE_OK {
      if sqlite3_step(stateStmt) == SQLITE_ROW {
        let count = sqlite3_column_int(stateStmt, 0)
        if count == 0 {
          sqlite3_exec(
            stateDb,
            "ALTER TABLE panels ADD COLUMN is_minimized INTEGER NOT NULL DEFAULT 0",
            nil, nil, nil)
          sqlite3_exec(
            stateDb,
            "ALTER TABLE panels ADD COLUMN remembered_ratio REAL",
            nil, nil, nil)
        }
      }
    }
    sqlite3_finalize(stateStmt)

    // Migrate from windows.json or old logs.db if needed
    migrateWindowStateIfNeeded()
  }

  /// Migrate window state from windows.json or old logs.db to state.db (idempotent)
  private func migrateWindowStateIfNeeded() {
    // Check if we already have windows in state.db
    var stmt: OpaquePointer?
    let countSql = "SELECT COUNT(*) FROM windows"
    if sqlite3_prepare_v2(stateDb, countSql, -1, &stmt, nil) == SQLITE_OK {
      if sqlite3_step(stmt) == SQLITE_ROW {
        let count = sqlite3_column_int(stmt, 0)
        if count > 0 {
          sqlite3_finalize(stmt)
          os_log(
            "state.db already has %d windows, skipping migration", log: Logger.persistence,
            type: .debug, count)
          return
        }
      }
    }
    sqlite3_finalize(stmt)

    // Try to migrate from old logs.db first (if windows table exists there)
    if migrateFromOldLogsDb() {
      return
    }

    // Fall back to windows.json migration
    guard fileManager.fileExists(atPath: multiWindowStateFilePath.path) else {
      os_log("No windows.json found, skipping migration", log: Logger.persistence, type: .debug)
      return
    }

    // Load from JSON
    do {
      let data = try Data(contentsOf: multiWindowStateFilePath)
      let decoder = JSONDecoder()
      let state = try decoder.decode(MultiWindowState.self, from: data)

      // Import into SQLite state.db
      saveMultiWindowStateToSQLiteSync(state)

      // Rename the old file to indicate migration completed
      let backupPath = multiWindowStateFilePath.appendingPathExtension("migrated")
      try? fileManager.moveItem(at: multiWindowStateFilePath, to: backupPath)

      os_log(
        "Migrated %d windows from JSON to state.db", log: Logger.persistence, type: .info,
        state.windows.count)
    } catch {
      os_log(
        "Error migrating windows.json: %{public}@", log: Logger.persistence, type: .error,
        error.localizedDescription)
    }
  }

  /// Migrate windows from old logs.db to state.db (returns true if migration happened)
  private func migrateFromOldLogsDb() -> Bool {
    // Check if logs.db has a windows table
    var stmt: OpaquePointer?
    let checkSql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='windows'"
    if sqlite3_prepare_v2(db, checkSql, -1, &stmt, nil) == SQLITE_OK {
      if sqlite3_step(stmt) == SQLITE_ROW {
        let count = sqlite3_column_int(stmt, 0)
        if count == 0 {
          sqlite3_finalize(stmt)
          return false  // No windows table in logs.db
        }
      }
    }
    sqlite3_finalize(stmt)

    // Count windows in logs.db
    if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM windows", -1, &stmt, nil) == SQLITE_OK {
      if sqlite3_step(stmt) == SQLITE_ROW {
        let count = sqlite3_column_int(stmt, 0)
        if count == 0 {
          sqlite3_finalize(stmt)
          return false  // No windows to migrate
        }
      }
    }
    sqlite3_finalize(stmt)

    os_log("Migrating windows from logs.db to state.db", log: Logger.persistence, type: .info)

    // Copy windows
    let windowSql =
      "SELECT id, last_working_directory, last_command, frame_x, frame_y, frame_width, frame_height, layout_json, updated_at FROM windows"
    if sqlite3_prepare_v2(db, windowSql, -1, &stmt, nil) == SQLITE_OK {
      while sqlite3_step(stmt) == SQLITE_ROW {
        var insertStmt: OpaquePointer?
        let insertSql =
          "INSERT OR REPLACE INTO windows (id, last_working_directory, last_command, frame_x, frame_y, frame_width, frame_height, layout_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        if sqlite3_prepare_v2(stateDb, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
          // Copy all columns
          for i: Int32 in 0..<9 {
            let colType = sqlite3_column_type(stmt, i)
            switch colType {
            case SQLITE_TEXT:
              let text = sqlite3_column_text(stmt, i)
              sqlite3_bind_text(
                insertStmt, i + 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case SQLITE_FLOAT:
              sqlite3_bind_double(insertStmt, i + 1, sqlite3_column_double(stmt, i))
            case SQLITE_NULL:
              sqlite3_bind_null(insertStmt, i + 1)
            default:
              sqlite3_bind_null(insertStmt, i + 1)
            }
          }
          sqlite3_step(insertStmt)
        }
        sqlite3_finalize(insertStmt)
      }
    }
    sqlite3_finalize(stmt)

    // Copy panels
    let panelSql =
      "SELECT id, window_id, title, handle_id, status_json, config_json, position FROM panels"
    if sqlite3_prepare_v2(db, panelSql, -1, &stmt, nil) == SQLITE_OK {
      while sqlite3_step(stmt) == SQLITE_ROW {
        var insertStmt: OpaquePointer?
        let insertSql =
          "INSERT OR REPLACE INTO panels (id, window_id, title, handle_id, status_json, config_json, position) VALUES (?, ?, ?, ?, ?, ?, ?)"
        if sqlite3_prepare_v2(stateDb, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
          for i: Int32 in 0..<7 {
            let colType = sqlite3_column_type(stmt, i)
            switch colType {
            case SQLITE_TEXT:
              let text = sqlite3_column_text(stmt, i)
              sqlite3_bind_text(
                insertStmt, i + 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case SQLITE_INTEGER:
              sqlite3_bind_int(insertStmt, i + 1, sqlite3_column_int(stmt, i))
            case SQLITE_NULL:
              sqlite3_bind_null(insertStmt, i + 1)
            default:
              sqlite3_bind_null(insertStmt, i + 1)
            }
          }
          sqlite3_step(insertStmt)
        }
        sqlite3_finalize(insertStmt)
      }
    }
    sqlite3_finalize(stmt)

    // Drop tables from logs.db after successful migration
    sqlite3_exec(db, "DROP TABLE IF EXISTS panels", nil, nil, nil)
    sqlite3_exec(db, "DROP TABLE IF EXISTS windows", nil, nil, nil)

    os_log("Completed migration from logs.db to state.db", log: Logger.persistence, type: .info)
    return true
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
          os_log(
            "Error inserting log line: %{public}@", log: Logger.persistence, type: .error,
            String(cString: sqlite3_errmsg(db)))
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
            os_log(
              "Error inserting log line: %{public}@", log: Logger.persistence, type: .error,
              String(cString: sqlite3_errmsg(db)))
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
        os_log(
          "Read %{public}d lines for panel in %.3fs", log: Logger.persistence, type: .debug,
          results.count, duration)
      }

      return results
    }
  }

  /// Read log lines asynchronously using a transient read-only connection
  /// This allows multiple panels to load in parallel, bypassing the serial dbQueue
  func readLogAsync(for panelId: UUID, limit: Int = 10000) async -> [(
    text: String, timestamp: Date, kind: LogEntryKind
  )] {
    let path = logsDatabasePath.path
    var localDb: OpaquePointer?

    // Open a new read-only connection for this operation
    if sqlite3_open_v2(path, &localDb, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
      os_log(
        "Error opening local database connection: %{public}@", log: Logger.persistence,
        type: .error, String(cString: sqlite3_errmsg(localDb)))
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
          os_log(
            "Error deleting log: %{public}@", log: Logger.persistence, type: .error,
            String(cString: sqlite3_errmsg(db)))
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

    // Auto-reload settings
    let autoReloadEnabled: Bool
    let autoReloadIncludes: [String]
    let autoReloadExcludes: [String]

    // Output filters
    let outputExcludeFilters: [String]
    let highlightPatterns: [String]

    /// Display name for the entry
    var displayName: String {
      name.isEmpty ? command : name
    }
  }

  /// Record a process run in history
  func recordRun(config: ProcessConfig) {
    dbQueue.async { [weak self] in
      guard let self = self, let db = self.db else { return }

      let sql = """
        INSERT INTO run_history (
          name, command, working_directory, shell, started_at,
          auto_reload_enabled, auto_reload_includes, auto_reload_excludes,
          output_exclude_filters, highlight_patterns
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
      var stmt: OpaquePointer?

      // Encode arrays as JSON
      let encoder = JSONEncoder()
      let includesJson =
        (try? encoder.encode(config.autoReloadIncludes)).flatMap {
          String(data: $0, encoding: .utf8)
        } ?? "[]"
      let excludesJson =
        (try? encoder.encode(config.autoReloadExcludes)).flatMap {
          String(data: $0, encoding: .utf8)
        } ?? "[]"
      let outputFiltersJson =
        (try? encoder.encode(config.outputExcludeFilters ?? [])).flatMap {
          String(data: $0, encoding: .utf8)
        } ?? "[]"
      let highlightJson =
        (try? encoder.encode(config.highlightPatterns ?? [])).flatMap {
          String(data: $0, encoding: .utf8)
        } ?? "[]"

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(
          stmt, 1, config.name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 2, config.command, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 3, config.workingDirectory, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 4, config.shell, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_bind_int(stmt, 6, config.autoReloadEnabled ? 1 : 0)
        sqlite3_bind_text(
          stmt, 7, includesJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 8, excludesJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 9, outputFiltersJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 10, highlightJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) != SQLITE_DONE {
          os_log(
            "Error recording run: %{public}@", log: Logger.persistence, type: .error,
            String(cString: sqlite3_errmsg(db)))
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
        SELECT id, name, command, working_directory, shell, started_at,
               auto_reload_enabled, auto_reload_includes, auto_reload_excludes,
               output_exclude_filters, highlight_patterns
        FROM run_history
        ORDER BY started_at DESC
        LIMIT ?
        """
      var stmt: OpaquePointer?
      let decoder = JSONDecoder()

      if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
          let id = sqlite3_column_int64(stmt, 0)
          let name = String(cString: sqlite3_column_text(stmt, 1))
          let command = String(cString: sqlite3_column_text(stmt, 2))
          let workingDirectory = String(cString: sqlite3_column_text(stmt, 3))
          let shell = String(cString: sqlite3_column_text(stmt, 4))
          let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

          // New columns (with safe defaults for old records)
          let autoReloadEnabled = sqlite3_column_int(stmt, 6) != 0

          let includesJson =
            sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]"
          let autoReloadIncludes =
            (try? decoder.decode([String].self, from: Data(includesJson.utf8))) ?? []

          let excludesJson =
            sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "[]"
          let autoReloadExcludes =
            (try? decoder.decode([String].self, from: Data(excludesJson.utf8))) ?? []

          let outputFiltersJson =
            sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "[]"
          let outputExcludeFilters =
            (try? decoder.decode([String].self, from: Data(outputFiltersJson.utf8))) ?? []

          let highlightJson =
            sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "[]"
          let highlightPatterns =
            (try? decoder.decode([String].self, from: Data(highlightJson.utf8))) ?? []

          results.append(
            RunHistoryEntry(
              id: id,
              name: name,
              command: command,
              workingDirectory: workingDirectory,
              shell: shell,
              startedAt: startedAt,
              autoReloadEnabled: autoReloadEnabled,
              autoReloadIncludes: autoReloadIncludes,
              autoReloadExcludes: autoReloadExcludes,
              outputExcludeFilters: outputExcludeFilters,
              highlightPatterns: highlightPatterns
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
    openDatabases()
    createTables()
  }

  // MARK: - Multi-Window State

  /// Path to legacy multi-window state file (for migration)
  private var multiWindowStateFilePath: URL {
    appSupportDirectory.appendingPathComponent("windows.json")
  }

  /// Path to settings file
  private var settingsFilePath: URL {
    appSupportDirectory.appendingPathComponent("settings.json")
  }

  /// Save multi-window state to SQLite
  func saveMultiWindowState(_ state: MultiWindowState) {
    saveMultiWindowStateToSQLite(state)
  }

  /// Internal method to save state to SQLite (used by both save and migration)
  private func saveMultiWindowStateToSQLite(_ state: MultiWindowState) {
    dbQueue.async { [weak self] in
      guard let self = self, let stateDb = self.stateDb else { return }

      let encoder = JSONEncoder()
      let now = Date().timeIntervalSince1970

      sqlite3_exec(stateDb, "BEGIN TRANSACTION", nil, nil, nil)

      // Get existing window IDs in SQLite
      var existingWindowIds = Set<String>()
      var stmt: OpaquePointer?
      if sqlite3_prepare_v2(stateDb, "SELECT id FROM windows", -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
          if let idPtr = sqlite3_column_text(stmt, 0) {
            existingWindowIds.insert(String(cString: idPtr))
          }
        }
      }
      sqlite3_finalize(stmt)

      // Track which windows are in the new state
      var newWindowIds = Set<String>()

      for windowData in state.windows {
        let windowId = windowData.windowId.uuidString
        newWindowIds.insert(windowId)

        // Encode layout as JSON
        var layoutJson: String? = nil
        if let layout = windowData.layout {
          if let data = try? encoder.encode(layout) {
            layoutJson = String(data: data, encoding: .utf8)
          }
        }

        // Upsert window
        let windowSql = """
          INSERT INTO windows (id, last_working_directory, last_command, frame_x, frame_y, frame_width, frame_height, layout_json, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            last_working_directory = excluded.last_working_directory,
            last_command = excluded.last_command,
            frame_x = excluded.frame_x,
            frame_y = excluded.frame_y,
            frame_width = excluded.frame_width,
            frame_height = excluded.frame_height,
            layout_json = excluded.layout_json,
            updated_at = excluded.updated_at
          """
        if sqlite3_prepare_v2(stateDb, windowSql, -1, &stmt, nil) == SQLITE_OK {
          sqlite3_bind_text(
            stmt, 1, windowId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          sqlite3_bind_text(
            stmt, 2, windowData.lastWorkingDirectory, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          if let cmd = windowData.lastCommand {
            sqlite3_bind_text(stmt, 3, cmd, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          } else {
            sqlite3_bind_null(stmt, 3)
          }
          if let x = windowData.frameX {
            sqlite3_bind_double(stmt, 4, Double(x))
          } else {
            sqlite3_bind_null(stmt, 4)
          }
          if let y = windowData.frameY {
            sqlite3_bind_double(stmt, 5, Double(y))
          } else {
            sqlite3_bind_null(stmt, 5)
          }
          if let w = windowData.frameWidth {
            sqlite3_bind_double(stmt, 6, Double(w))
          } else {
            sqlite3_bind_null(stmt, 6)
          }
          if let h = windowData.frameHeight {
            sqlite3_bind_double(stmt, 7, Double(h))
          } else {
            sqlite3_bind_null(stmt, 7)
          }
          if let json = layoutJson {
            sqlite3_bind_text(
              stmt, 8, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          } else {
            sqlite3_bind_null(stmt, 8)
          }
          sqlite3_bind_double(stmt, 9, now)

          if sqlite3_step(stmt) != SQLITE_DONE {
            os_log(
              "Error saving window: %{public}@", log: Logger.persistence, type: .error,
              String(cString: sqlite3_errmsg(stateDb)))
          }
        }
        sqlite3_finalize(stmt)

        // Delete existing panels for this window
        let deletePanelsSql = "DELETE FROM panels WHERE window_id = ?"
        if sqlite3_prepare_v2(stateDb, deletePanelsSql, -1, &stmt, nil) == SQLITE_OK {
          sqlite3_bind_text(
            stmt, 1, windowId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Insert panels
        let panelSql =
          "INSERT INTO panels (id, window_id, title, handle_id, status_json, config_json, position, is_minimized, remembered_ratio) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        for (position, panel) in windowData.panels.enumerated() {
          let statusJson =
            (try? encoder.encode(panel.status)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
          let configJson = panel.processConfig.flatMap { try? encoder.encode($0) }.flatMap {
            String(data: $0, encoding: .utf8)
          }

          if sqlite3_prepare_v2(stateDb, panelSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(
              stmt, 1, panel.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(
              stmt, 2, windowId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(
              stmt, 3, panel.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let handleId = panel.handleId {
              sqlite3_bind_text(
                stmt, 4, handleId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
              sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(
              stmt, 5, statusJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let cJson = configJson {
              sqlite3_bind_text(
                stmt, 6, cJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
              sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int(stmt, 7, Int32(position))
            sqlite3_bind_int(stmt, 8, (panel.isMinimized ?? false) ? 1 : 0)
            if let ratio = panel.rememberedRatio {
              sqlite3_bind_double(stmt, 9, ratio)
            } else {
              sqlite3_bind_null(stmt, 9)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
              os_log(
                "Error saving panel: %{public}@", log: Logger.persistence, type: .error,
                String(cString: sqlite3_errmsg(stateDb)))
            }
          }
          sqlite3_finalize(stmt)
        }
      }

      // Note: We don't auto-delete windows not in the current state.
      // Windows are only deleted when explicitly closed via deleteWindow().
      // This prevents data loss if a window fails to restore during startup.

      sqlite3_exec(stateDb, "COMMIT", nil, nil, nil)
      os_log(
        "Saved multi-window state to SQLite (%d windows)", log: Logger.persistence, type: .debug,
        state.windows.count)
    }
  }

  /// Synchronous version for migration (called during startup before dbQueue is used)
  private func saveMultiWindowStateToSQLiteSync(_ state: MultiWindowState) {
    guard let stateDb = self.stateDb else { return }

    let encoder = JSONEncoder()
    let now = Date().timeIntervalSince1970

    sqlite3_exec(stateDb, "BEGIN TRANSACTION", nil, nil, nil)

    for windowData in state.windows {
      let windowId = windowData.windowId.uuidString

      // Encode layout as JSON
      var layoutJson: String? = nil
      if let layout = windowData.layout {
        if let data = try? encoder.encode(layout) {
          layoutJson = String(data: data, encoding: .utf8)
        }
      }

      // Upsert window
      let windowSql = """
        INSERT INTO windows (id, last_working_directory, last_command, frame_x, frame_y, frame_width, frame_height, layout_json, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          last_working_directory = excluded.last_working_directory,
          last_command = excluded.last_command,
          frame_x = excluded.frame_x,
          frame_y = excluded.frame_y,
          frame_width = excluded.frame_width,
          frame_height = excluded.frame_height,
          layout_json = excluded.layout_json,
          updated_at = excluded.updated_at
        """
      var stmt: OpaquePointer?
      if sqlite3_prepare_v2(stateDb, windowSql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(
          stmt, 1, windowId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(
          stmt, 2, windowData.lastWorkingDirectory, -1,
          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let cmd = windowData.lastCommand {
          sqlite3_bind_text(stmt, 3, cmd, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
          sqlite3_bind_null(stmt, 3)
        }
        if let x = windowData.frameX {
          sqlite3_bind_double(stmt, 4, Double(x))
        } else {
          sqlite3_bind_null(stmt, 4)
        }
        if let y = windowData.frameY {
          sqlite3_bind_double(stmt, 5, Double(y))
        } else {
          sqlite3_bind_null(stmt, 5)
        }
        if let w = windowData.frameWidth {
          sqlite3_bind_double(stmt, 6, Double(w))
        } else {
          sqlite3_bind_null(stmt, 6)
        }
        if let h = windowData.frameHeight {
          sqlite3_bind_double(stmt, 7, Double(h))
        } else {
          sqlite3_bind_null(stmt, 7)
        }
        if let json = layoutJson {
          sqlite3_bind_text(stmt, 8, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
          sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_double(stmt, 9, now)

        if sqlite3_step(stmt) != SQLITE_DONE {
          os_log(
            "Error saving window: %{public}@", log: Logger.persistence, type: .error,
            String(cString: sqlite3_errmsg(stateDb)))
        }
      }
      sqlite3_finalize(stmt)

      // Insert panels
      let panelSql =
        "INSERT INTO panels (id, window_id, title, handle_id, status_json, config_json, position, is_minimized, remembered_ratio) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
      for (position, panel) in windowData.panels.enumerated() {
        let statusJson =
          (try? encoder.encode(panel.status)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let configJson = panel.processConfig.flatMap { try? encoder.encode($0) }.flatMap {
          String(data: $0, encoding: .utf8)
        }

        if sqlite3_prepare_v2(stateDb, panelSql, -1, &stmt, nil) == SQLITE_OK {
          sqlite3_bind_text(
            stmt, 1, panel.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          sqlite3_bind_text(
            stmt, 2, windowId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          sqlite3_bind_text(
            stmt, 3, panel.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          if let handleId = panel.handleId {
            sqlite3_bind_text(
              stmt, 4, handleId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          } else {
            sqlite3_bind_null(stmt, 4)
          }
          sqlite3_bind_text(
            stmt, 5, statusJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          if let cJson = configJson {
            sqlite3_bind_text(
              stmt, 6, cJson, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          } else {
            sqlite3_bind_null(stmt, 6)
          }
          sqlite3_bind_int(stmt, 7, Int32(position))
          sqlite3_bind_int(stmt, 8, (panel.isMinimized ?? false) ? 1 : 0)
          if let ratio = panel.rememberedRatio {
            sqlite3_bind_double(stmt, 9, ratio)
          } else {
            sqlite3_bind_null(stmt, 9)
          }

          if sqlite3_step(stmt) != SQLITE_DONE {
            os_log(
              "Error saving panel: %{public}@", log: Logger.persistence, type: .error,
              String(cString: sqlite3_errmsg(stateDb)))
          }
        }
        sqlite3_finalize(stmt)
      }
    }

    sqlite3_exec(stateDb, "COMMIT", nil, nil, nil)
    os_log(
      "Migrated %d windows to state.db", log: Logger.persistence, type: .info, state.windows.count)
  }

  /// Load multi-window state from SQLite
  func loadMultiWindowState() -> MultiWindowState? {
    return dbQueue.sync { [weak self] () -> MultiWindowState? in
      guard let self = self, let stateDb = self.stateDb else { return nil }

      let decoder = JSONDecoder()
      var windows: [WindowStateData] = []

      // Load windows
      let windowSql =
        "SELECT id, last_working_directory, last_command, frame_x, frame_y, frame_width, frame_height, layout_json FROM windows ORDER BY updated_at DESC"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(stateDb, windowSql, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
          guard let idPtr = sqlite3_column_text(stmt, 0),
            let dirPtr = sqlite3_column_text(stmt, 1)
          else { continue }

          let windowId = UUID(uuidString: String(cString: idPtr)) ?? UUID()
          let lastDir = String(cString: dirPtr)
          let lastCmd = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
          let frameX =
            sqlite3_column_type(stmt, 3) != SQLITE_NULL
            ? CGFloat(sqlite3_column_double(stmt, 3)) : nil
          let frameY =
            sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? CGFloat(sqlite3_column_double(stmt, 4)) : nil
          let frameWidth =
            sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? CGFloat(sqlite3_column_double(stmt, 5)) : nil
          let frameHeight =
            sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? CGFloat(sqlite3_column_double(stmt, 6)) : nil

          var layout: LayoutNode? = nil
          if let layoutPtr = sqlite3_column_text(stmt, 7),
            let layoutData = String(cString: layoutPtr).data(using: .utf8)
          {
            layout = try? decoder.decode(LayoutNode.self, from: layoutData)
          }

          // Load panels for this window
          var panels: [PanelState] = []
          let panelSql =
            "SELECT id, title, handle_id, status_json, config_json, is_minimized, remembered_ratio FROM panels WHERE window_id = ? ORDER BY position"
          var panelStmt: OpaquePointer?

          if sqlite3_prepare_v2(stateDb, panelSql, -1, &panelStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(
              panelStmt, 1, windowId.uuidString, -1,
              unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(panelStmt) == SQLITE_ROW {
              guard let panelIdPtr = sqlite3_column_text(panelStmt, 0),
                let titlePtr = sqlite3_column_text(panelStmt, 1),
                let statusPtr = sqlite3_column_text(panelStmt, 3)
              else { continue }

              let panelId = UUID(uuidString: String(cString: panelIdPtr)) ?? UUID()
              let title = String(cString: titlePtr)
              let handleId = sqlite3_column_text(panelStmt, 2).map { String(cString: $0) }

              let status: PanelStatusState
              if let statusData = String(cString: statusPtr).data(using: .utf8),
                let decoded = try? decoder.decode(PanelStatusState.self, from: statusData)
              {
                status = decoded
              } else {
                status = .exitedNormally
              }

              var config: ProcessConfigState? = nil
              if let configPtr = sqlite3_column_text(panelStmt, 4),
                let configData = String(cString: configPtr).data(using: .utf8)
              {
                config = try? decoder.decode(ProcessConfigState.self, from: configData)
              }

              // Read minimize state (column 5) - defaults to false if NULL or missing
              let isMinimized =
                sqlite3_column_type(panelStmt, 5) != SQLITE_NULL
                ? sqlite3_column_int(panelStmt, 5) != 0 : false
              // Read remembered ratio (column 6) - nil if NULL
              let rememberedRatio: CGFloat? =
                sqlite3_column_type(panelStmt, 6) != SQLITE_NULL
                ? CGFloat(sqlite3_column_double(panelStmt, 6)) : nil

              panels.append(
                PanelState(
                  id: panelId, title: title, processConfig: config, status: status,
                  handleId: handleId, isMinimized: isMinimized, rememberedRatio: rememberedRatio))
            }
          }
          sqlite3_finalize(panelStmt)

          windows.append(
            WindowStateData(
              windowId: windowId,
              panels: panels,
              layout: layout,
              lastWorkingDirectory: lastDir,
              lastCommand: lastCmd,
              frameX: frameX,
              frameY: frameY,
              frameWidth: frameWidth,
              frameHeight: frameHeight
            ))
        }
      }
      sqlite3_finalize(stmt)

      if windows.isEmpty {
        return nil
      }

      os_log(
        "Loaded multi-window state from SQLite (%d windows)", log: Logger.persistence, type: .debug,
        windows.count)
      return MultiWindowState(windows: windows)
    }
  }

  /// Delete a specific window from SQLite (called when user closes a window)
  func deleteWindow(_ windowId: UUID) {
    dbQueue.async { [weak self] in
      guard let self = self, let stateDb = self.stateDb else { return }

      // Panels will be deleted by CASCADE
      let sql = "DELETE FROM windows WHERE id = ?"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(stateDb, sql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(
          stmt, 1, windowId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_DONE {
          os_log(
            "Deleted window %{public}@ from state.db", log: Logger.persistence, type: .debug,
            windowId.uuidString)
        }
      }
      sqlite3_finalize(stmt)
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
      os_log(
        "Error saving settings: %{public}@", log: Logger.persistence, type: .error,
        error.localizedDescription)
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
      os_log(
        "Error loading settings: %{public}@", log: Logger.persistence, type: .error,
        error.localizedDescription)
      return nil
    }
  }

  // MARK: - Log Retention Cleanup

  /// Start periodic cleanup timer
  private func startCleanupTimer() {
    let timer = DispatchSource.makeTimerSource(queue: dbQueue)
    // Start after 1 min, repeat based on constant
    timer.schedule(deadline: .now() + 60, repeating: Constants.logCleanupIntervalSeconds)
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
      os_log(
        "Log retention cleanup: deleted %{public}d old entries", log: Logger.persistence,
        type: .info, totalDeleted)
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

// Types moved to SharedTypes.swift
