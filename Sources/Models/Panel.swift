import Foundation
import SwiftUI

/// Represents the status of a process
enum ProcessStatus: Equatable {
  case running
  case exitedNormally
  case exitedWithError(code: Int32)
  case restarting(target: Date)

  var color: Color {
    switch self {
    case .running:
      return .green
    case .exitedNormally:
      return .gray
    case .exitedWithError:
      return .red
    case .restarting:
      return .orange
    }
  }
}

/// Cache for parsed line segments (avoids re-parsing on every render)
final class LineSegmentCache {
  static let shared = LineSegmentCache()
  private var cache: [UUID: [OutputSegment]] = [:]
  private let lock = NSLock()
  private let maxCacheSize = 5000

  func get(_ id: UUID, rawText: String) -> [OutputSegment] {
    lock.lock()
    if let cached = cache[id] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    // Parse outside lock
    let parsed = OutputLine.parse(rawText)

    lock.lock()
    // Evict old entries if cache is too large
    if cache.count > maxCacheSize {
      // Remove ~20% of entries (simple eviction)
      let keysToRemove = Array(cache.keys.prefix(maxCacheSize / 5))
      for key in keysToRemove {
        cache.removeValue(forKey: key)
      }
    }
    cache[id] = parsed
    lock.unlock()

    return parsed
  }

  func remove(_ id: UUID) {
    lock.lock()
    cache.removeValue(forKey: id)
    lock.unlock()
  }

  func clear() {
    lock.lock()
    cache.removeAll()
    lock.unlock()
  }
}

/// A single output line from a process, supporting ANSI colors
struct OutputLine: Identifiable, Equatable {
  let id: UUID
  let rawText: String
  let timestamp: Date
  let kind: LogEntryKind

  init(text: String, timestamp: Date = Date(), kind: LogEntryKind = .output, id: UUID = UUID()) {
    self.id = id
    self.rawText = text
    self.timestamp = timestamp
    self.kind = kind
  }

  /// Parsed segments - uses cache for lazy parsing
  var segments: [OutputSegment] {
    LineSegmentCache.shared.get(id, rawText: rawText)
  }

  /// Whether this is a meta-line (not regular output)
  var isMeta: Bool {
    kind != .output
  }

  static func == (lhs: OutputLine, rhs: OutputLine) -> Bool {
    lhs.id == rhs.id
  }

  /// Regex to match non-SGR ANSI escape sequences (cursor movement, erase, etc.)
  /// Matches ESC sequences that DON'T end in 'm' (which are SGR/color codes)
  private static let nonSgrAnsiRegex = try! NSRegularExpression(
    pattern: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-ln-~])",
    options: []
  )

  /// Regex to match OSC sequences (e.g., shell integration, title changes)
  private static let oscRegex = try! NSRegularExpression(
    pattern: "\\x1B\\].*?(?:\\x07|\\x1B\\\\)",
    options: [.dotMatchesLineSeparators]
  )

  /// Regex to match SGR (color/style) sequences - capture the codes
  private static let sgrRegex = try! NSRegularExpression(
    pattern: "\\x1B\\[([0-9;]*)m",
    options: []
  )

  /// Parse text into segments, handling ANSI colors and non-printables
  static func parse(_ text: String) -> [OutputSegment] {
    // First, strip OSC sequences (shell integration, window titles, etc.)
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    let withoutOsc = oscRegex.stringByReplacingMatches(
      in: text, options: [], range: fullRange, withTemplate: "")

    // Then strip non-SGR ANSI sequences (cursor movement, etc.)
    let withoutOscNs = withoutOsc as NSString
    let strippedText = nonSgrAnsiRegex.stringByReplacingMatches(
      in: withoutOsc,
      options: [],
      range: NSRange(location: 0, length: withoutOscNs.length),
      withTemplate: ""
    )

    // Now parse the text with only SGR sequences remaining
    var segments: [OutputSegment] = []
    var currentStyle = TextStyle()
    var currentText = ""
    var i = strippedText.startIndex

    while i < strippedText.endIndex {
      let char = strippedText[i]

      // Check for ESC sequence
      if char == "\u{1B}" {
        // Look for SGR sequence: ESC [ <codes> m
        let remaining = String(strippedText[i...])
        let nsRemaining = remaining as NSString
        let matchRange = NSRange(location: 0, length: nsRemaining.length)

        if let match = sgrRegex.firstMatch(in: remaining, options: .anchored, range: matchRange) {
          // Flush current text
          if !currentText.isEmpty {
            segments.append(contentsOf: parseNonPrintables(currentText, style: currentStyle))
            currentText = ""
          }

          // Extract and apply codes
          let codesRange = match.range(at: 1)
          let codesStr =
            codesRange.location != NSNotFound ? nsRemaining.substring(with: codesRange) : ""
          let codes = codesStr.split(separator: ";").compactMap { Int($0) }
          currentStyle = applyAnsiCodes(codes, to: currentStyle)

          // Skip past the SGR sequence
          i = strippedText.index(i, offsetBy: match.range.length)
          continue
        }
      }

      // Regular character
      currentText.append(char)
      i = strippedText.index(after: i)
    }

    // Flush remaining text
    if !currentText.isEmpty {
      segments.append(contentsOf: parseNonPrintables(currentText, style: currentStyle))
    }

    return segments
  }

  /// Parse text for non-printable characters only
  private static func parseNonPrintables(_ text: String, style: TextStyle) -> [OutputSegment] {
    var segments: [OutputSegment] = []
    var currentText = ""

    for char in text {
      if char.isNonPrintable {
        if !currentText.isEmpty {
          segments.append(.text(currentText, style))
          currentText = ""
        }
        segments.append(.nonPrintable(char.nonPrintableName))
      } else {
        currentText.append(char)
      }
    }

    if !currentText.isEmpty {
      segments.append(.text(currentText, style))
    }

    return segments
  }

  /// Apply ANSI codes to style
  private static func applyAnsiCodes(_ codes: [Int], to style: TextStyle) -> TextStyle {
    var newStyle = style

    var i = 0
    while i < codes.count {
      let code = codes[i]

      switch code {
      case 0:
        newStyle = TextStyle()  // Reset
      case 1:
        newStyle.bold = true
      case 2:
        newStyle.dim = true
      case 3:
        newStyle.italic = true
      case 4:
        newStyle.underline = true
      case 22:
        newStyle.bold = false
        newStyle.dim = false
      case 23:
        newStyle.italic = false
      case 24:
        newStyle.underline = false
      case 30...37:
        newStyle.foreground = basicColor(code - 30)
      case 38:
        // Extended foreground color
        if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
          newStyle.foreground = color256(codes[i + 2])
          i += 2
        }
      case 39:
        newStyle.foreground = nil  // Default foreground
      case 40...47:
        newStyle.background = basicColor(code - 40)
      case 48:
        // Extended background color
        if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
          newStyle.background = color256(codes[i + 2])
          i += 2
        }
      case 49:
        newStyle.background = nil  // Default background
      case 90...97:
        newStyle.foreground = brightColor(code - 90)
      case 100...107:
        newStyle.background = brightColor(code - 100)
      default:
        break
      }

      i += 1
    }

    return newStyle
  }

  private static func basicColor(_ index: Int) -> Color {
    switch index {
    case 0: return .black
    case 1: return .red
    case 2: return .green
    case 3: return .yellow
    case 4: return .blue
    case 5: return .purple
    case 6: return .cyan
    case 7: return .white
    default: return .primary
    }
  }

  private static func brightColor(_ index: Int) -> Color {
    switch index {
    case 0: return Color(red: 0.5, green: 0.5, blue: 0.5)
    case 1: return Color(red: 1.0, green: 0.3, blue: 0.3)
    case 2: return Color(red: 0.3, green: 1.0, blue: 0.3)
    case 3: return Color(red: 1.0, green: 1.0, blue: 0.3)
    case 4: return Color(red: 0.3, green: 0.3, blue: 1.0)
    case 5: return Color(red: 1.0, green: 0.3, blue: 1.0)
    case 6: return Color(red: 0.3, green: 1.0, blue: 1.0)
    case 7: return Color.white
    default: return .primary
    }
  }

  private static func color256(_ index: Int) -> Color {
    if index < 16 {
      return index < 8 ? basicColor(index) : brightColor(index - 8)
    } else if index < 232 {
      // 216 color cube
      let adjusted = index - 16
      let r = Double((adjusted / 36) % 6) / 5.0
      let g = Double((adjusted / 6) % 6) / 5.0
      let b = Double(adjusted % 6) / 5.0
      return Color(red: r, green: g, blue: b)
    } else {
      // Grayscale
      let gray = Double(index - 232) / 23.0
      return Color(red: gray, green: gray, blue: gray)
    }
  }
}

/// A segment of output text
enum OutputSegment: Equatable {
  case text(String, TextStyle)
  case nonPrintable(String)
}

/// Style for a text segment
struct TextStyle: Equatable {
  var foreground: Color?
  var background: Color?
  var bold: Bool = false
  var dim: Bool = false
  var italic: Bool = false
  var underline: Bool = false
}

extension Character {
  var isNonPrintable: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    // Control characters except newline and tab
    return scalar.value < 32 && scalar.value != 10 && scalar.value != 9
  }

  var nonPrintableName: String {
    guard let scalar = unicodeScalars.first else { return "?" }
    switch scalar.value {
    case 0: return "NUL"
    case 1: return "SOH"
    case 2: return "STX"
    case 3: return "ETX"
    case 4: return "EOT"
    case 5: return "ENQ"
    case 6: return "ACK"
    case 7: return "BEL"
    case 8: return "BS"
    case 11: return "VT"
    case 12: return "FF"
    case 13: return "CR"
    case 14: return "SO"
    case 15: return "SI"
    case 16: return "DLE"
    case 17: return "DC1"
    case 18: return "DC2"
    case 19: return "DC3"
    case 20: return "DC4"
    case 21: return "NAK"
    case 22: return "SYN"
    case 23: return "ETB"
    case 24: return "CAN"
    case 25: return "EM"
    case 26: return "SUB"
    case 27: return "ESC"
    case 28: return "FS"
    case 29: return "GS"
    case 30: return "RS"
    case 31: return "US"
    case 127: return "DEL"
    default: return "?"
    }
  }
}

/// Represents a panel containing process output
class Panel: ObservableObject, Identifiable, Equatable {
  let id: UUID
  @Published var title: String
  @Published var status: ProcessStatus
  @Published var lines: [OutputLine]
  @Published var isLoadingHistory: Bool = false
  /// Max buffer lines - uses SettingsManager.shared.maxLineHistory
  var maxBufferLines: Int {
    SettingsManager.shared.maxLineHistory
  }

  /// Selected line IDs for line-based selection
  @Published var selectedLineIDs: Set<UUID> = []

  /// The process configuration (for restart capability)
  var processConfig: ProcessConfig?

  /// The tmux handle ID for reconnection after app restart
  var tmuxHandleId: String?

  /// When the current/last process run started
  @Published var startedAt: Date?

  /// When the process stopped (nil if still running)
  @Published var stoppedAt: Date?

  init(
    id: UUID = UUID(),
    title: String,
    status: ProcessStatus = .running,
    lines: [OutputLine] = [],
    processConfig: ProcessConfig? = nil,
    tmuxHandleId: String? = nil,
    startedAt: Date? = nil,
    stoppedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.lines = lines
    self.processConfig = processConfig
    self.tmuxHandleId = tmuxHandleId
    self.startedAt = startedAt
    self.stoppedAt = stoppedAt
  }

  static func == (lhs: Panel, rhs: Panel) -> Bool {
    lhs.id == rhs.id
  }

  func appendLine(_ text: String, kind: LogEntryKind = .output) {
    let timestamp = Date()
    let line = OutputLine(text: text, timestamp: timestamp, kind: kind)
    lines.append(line)

    // Persist to database
    PersistenceManager.shared.appendToLog(panelId: id, line: text, timestamp: timestamp, kind: kind)

    // Trim buffer if needed
    if lines.count > maxBufferLines {
      lines.removeFirst(lines.count - maxBufferLines)
    }
  }

  /// Append multiple lines at once (more efficient for batched updates)
  func appendLines(_ texts: [String], kind: LogEntryKind = .output) {
    let timestamp = Date()
    let newLines = texts.map { OutputLine(text: $0, timestamp: timestamp, kind: kind) }
    lines.append(contentsOf: newLines)

    // Persist to database (all lines get same timestamp for batch)
    let timestamps = Array(repeating: timestamp, count: texts.count)
    PersistenceManager.shared.appendToLog(
      panelId: id, lines: texts, timestamps: timestamps, kind: kind)

    // Trim buffer if needed
    if lines.count > maxBufferLines {
      lines.removeFirst(lines.count - maxBufferLines)
    }
  }

  /// Append a meta event (started, stopped, etc.)
  func appendEvent(_ kind: LogEntryKind, message: String) {
    appendLine(message, kind: kind)
  }

  /// Prepend history lines (loaded asynchronously)
  /// Maintains existing lines that may have been added while history was loading
  func prependHistory(_ historyLines: [OutputLine]) {
    guard !historyLines.isEmpty else { return }

    // Combine history with current lines
    lines.insert(contentsOf: historyLines, at: 0)

    // Trim buffer if needed (though unlikely to exceed limit on startup unless limit changed)
    if lines.count > maxBufferLines {
      lines.removeFirst(lines.count - maxBufferLines)
    }
  }
}
