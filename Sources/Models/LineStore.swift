import Foundation

/// Manages a set of output lines with filtering support.
/// Provides efficient incremental updates and caches filter results.
/// Note: This is NOT an ObservableObject - Panel handles all change notifications.
final class LineStore {
  // MARK: - Storage

  /// All lines (source of truth)
  private var allLines: [OutputLine] = []

  /// Indices into allLines for lines that pass current filters
  private var visibleIndices: [Int] = []

  /// Cached visible lines array (invalidated when indices change)
  private var cachedVisibleLines: [OutputLine]?

  /// Panel ID for database persistence
  private var panelId: UUID?

  // MARK: - Filter Configuration

  /// Exclude patterns (lines matching any pattern are hidden)
  private var excludePatterns: [String] = []

  /// Compiled exclude regexes (cached)
  private var excludeRegexes: [NSRegularExpression] = []

  /// Search/filter pattern (only lines matching are shown)
  private var searchPattern: String = ""

  /// Compiled search regex (cached)
  private var searchRegex: NSRegularExpression?

  /// Maximum lines to keep in memory
  var maxLines: Int = 10000

  // MARK: - Public Interface

  /// Number of visible lines
  var visibleLineCount: Int {
    visibleIndices.count
  }

  /// Total line count (before filtering)
  var totalLineCount: Int {
    allLines.count
  }

  /// Get visible lines (cached, invalidated when lines change)
  var visibleLines: [OutputLine] {
    if let cached = cachedVisibleLines {
      return cached
    }
    let lines = visibleIndices.map { allLines[$0] }
    cachedVisibleLines = lines
    return lines
  }

  /// Get a specific visible line by index
  func visibleLine(at index: Int) -> OutputLine {
    allLines[visibleIndices[index]]
  }

  /// Check if any filters are active
  var hasActiveFilters: Bool {
    !excludeRegexes.isEmpty || searchRegex != nil
  }

  // MARK: - Initialization

  init(panelId: UUID? = nil) {
    self.panelId = panelId
  }

  /// Set the panel ID (for database persistence)
  func setPanelId(_ id: UUID) {
    self.panelId = id
  }

  // MARK: - Line Management

  /// Append a single line
  func append(_ line: OutputLine, persist: Bool = true) {
    let index = allLines.count
    allLines.append(line)

    if passesFilters(line) {
      visibleIndices.append(index)
      cachedVisibleLines = nil  // Invalidate cache
    }

    // Persist to database
    if persist, let panelId = panelId {
      PersistenceManager.shared.appendToLog(
        panelId: panelId,
        line: line.rawText,
        timestamp: line.timestamp,
        kind: line.kind
      )
    }

    // Trim if over max
    trimIfNeeded()
  }

  /// Append multiple lines (more efficient for batches)
  func append(contentsOf lines: [OutputLine], persist: Bool = true) {
    guard !lines.isEmpty else { return }

    let startIndex = allLines.count
    allLines.append(contentsOf: lines)

    // Check each new line against filters
    var anyVisible = false
    for (offset, line) in lines.enumerated() {
      if passesFilters(line) {
        visibleIndices.append(startIndex + offset)
        anyVisible = true
      }
    }
    if anyVisible {
      cachedVisibleLines = nil  // Invalidate cache
    }

    // Persist to database
    if persist, let panelId = panelId {
      let timestamps = lines.map { $0.timestamp }
      let texts = lines.map { $0.rawText }
      // Assume all same kind for batch
      let kind = lines.first?.kind ?? .output
      PersistenceManager.shared.appendToLog(
        panelId: panelId,
        lines: texts,
        timestamps: timestamps,
        kind: kind
      )
    }

    // Trim if over max
    trimIfNeeded()
  }

  /// Prepend historical lines (loaded from database, don't persist again)
  func prependHistory(_ lines: [OutputLine]) {
    guard !lines.isEmpty else { return }

    // Insert at beginning
    allLines.insert(contentsOf: lines, at: 0)

    // Rebuild visible indices (all indices shifted)
    rebuildVisibleIndices()
  }

  /// Clear all lines
  func clear() {
    allLines.removeAll()
    visibleIndices.removeAll()
    cachedVisibleLines = nil
  }

  /// Set all lines (replaces existing)
  func setLines(_ lines: [OutputLine]) {
    allLines = lines
    rebuildVisibleIndices()
  }

  // MARK: - Filter Management

  /// Set exclude patterns (lines matching any pattern are hidden)
  func setExcludePatterns(_ patterns: [String]) {
    guard patterns != excludePatterns else { return }

    excludePatterns = patterns
    excludeRegexes = patterns.compactMap { pattern in
      try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    rebuildVisibleIndices()
  }

  /// Set search pattern (only matching lines shown, empty means show all)
  func setSearchPattern(_ pattern: String) {
    let trimmed = pattern.trimmingCharacters(in: .whitespaces)
    guard trimmed != searchPattern else { return }

    searchPattern = trimmed

    if trimmed.isEmpty || trimmed == ".*" {
      searchRegex = nil
    } else {
      searchRegex = try? NSRegularExpression(pattern: trimmed, options: .caseInsensitive)
    }

    rebuildVisibleIndices()
  }

  /// Get current exclude patterns
  var currentExcludePatterns: [String] {
    excludePatterns
  }

  /// Get current search pattern
  var currentSearchPattern: String {
    searchPattern
  }

  // MARK: - Private Helpers

  /// Check if a line passes all active filters
  private func passesFilters(_ line: OutputLine) -> Bool {
    let text = line.plainText

    // Check search filter (must match if active)
    if let regex = searchRegex {
      let range = NSRange(text.startIndex..., in: text)
      if regex.firstMatch(in: text, options: [], range: range) == nil {
        return false
      }
    }

    // Check exclude filters (must not match any)
    if !excludeRegexes.isEmpty {
      // Limit to first 2000 chars to prevent regex backtracking
      // Use offsetBy:limitedBy: to avoid O(n) text.count operation
      let endIndex = text.index(text.startIndex, offsetBy: 2000, limitedBy: text.endIndex) ?? text.endIndex
      let range = NSRange(text.startIndex..<endIndex, in: text)

      for regex in excludeRegexes {
        if regex.firstMatch(in: text, options: [], range: range) != nil {
          return false  // Matched an exclude pattern
        }
      }
    }

    return true
  }

  /// Rebuild visible indices from scratch (after filter change)
  private func rebuildVisibleIndices() {
    if !hasActiveFilters {
      // No filters - all lines visible
      visibleIndices = Array(allLines.indices)
    } else {
      visibleIndices = allLines.indices.filter { passesFilters(allLines[$0]) }
    }
    cachedVisibleLines = nil  // Invalidate cache
  }

  /// Trim lines if over max capacity
  private func trimIfNeeded() {
    guard allLines.count > maxLines else { return }

    let removeCount = allLines.count - maxLines
    allLines.removeFirst(removeCount)

    // Adjust visible indices efficiently instead of rebuilding from scratch
    // This is O(visibleIndices.count) instead of O(allLines.count * filter_cost)
    var newIndices: [Int] = []
    newIndices.reserveCapacity(visibleIndices.count)
    for idx in visibleIndices {
      if idx >= removeCount {
        newIndices.append(idx - removeCount)
      }
    }
    visibleIndices = newIndices
    cachedVisibleLines = nil  // Invalidate cache
  }
}
