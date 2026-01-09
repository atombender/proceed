import AppKit
import CoreText
import SwiftUI

// MARK: - OutputLine to LogLine Conversion

extension LogLine {
  /// Create a LogLine from an OutputLine
  static func from(_ outputLine: OutputLine, font: NSFont) -> LogLine {
    let attrString = NSMutableAttributedString()

    for segment in outputLine.segments {
      switch segment {
      case .text(let text, let style):
        var attrs: [NSAttributedString.Key: Any] = [.font: font]

        // Foreground color
        if let fg = style.foreground {
          attrs[.foregroundColor] = NSColor(fg)
        } else {
          attrs[.foregroundColor] = NSColor.labelColor
        }

        // Background color
        if let bg = style.background {
          attrs[.backgroundColor] = NSColor(bg)
        }

        // Bold
        if style.bold {
          let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
          attrs[.font] = boldFont
        }

        // Italic
        if style.italic {
          let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
          attrs[.font] = italicFont
        }

        // Underline
        if style.underline {
          attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        // Dim
        if style.dim {
          attrs[.foregroundColor] = NSColor.secondaryLabelColor
        }

        attrString.append(NSAttributedString(string: text, attributes: attrs))

      case .nonPrintable(let name):
        // Render non-printables as small badges
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.75, weight: .medium),
          .foregroundColor: NSColor.secondaryLabelColor,
          .backgroundColor: NSColor.quaternaryLabelColor,
        ]
        attrString.append(NSAttributedString(string: " \(name) ", attributes: attrs))
      }
    }

    return LogLine(
      id: outputLine.id,
      timestamp: outputLine.timestamp,
      attributedContent: attrString,
      isMetaLine: outputLine.isMeta
    )
  }
}

// MARK: - Data Types

/// Represents a text selection range
struct TextSelection: Equatable {
  var startLine: Int
  var startChar: Int
  var endLine: Int
  var endChar: Int

  /// Normalized so start <= end
  var normalized: TextSelection {
    if startLine > endLine || (startLine == endLine && startChar > endChar) {
      return TextSelection(
        startLine: endLine, startChar: endChar, endLine: startLine, endChar: startChar)
    }
    return self
  }

  var isEmpty: Bool {
    startLine == endLine && startChar == endChar
  }
}

/// A single logical line with its content
struct LogLine {
  let id: UUID
  let timestamp: Date
  let attributedContent: NSAttributedString
  let isMetaLine: Bool

  /// Plain text for copying
  var plainText: String {
    attributedContent.string
  }
}

// MARK: - LogContentView

/// Custom view that renders log lines using NSAttributedString
/// Supports lazy rendering, text selection, and gutter for line selection
final class LogContentView: NSView {

  // MARK: - Configuration

  var gutterWidth: CGFloat = 85
  var lineSpacing: CGFloat = 2
  var contentPadding: CGFloat = 4
  var suppressDrawing: Bool = false  // Prevents drawing until initial scroll completes

  var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) {
    didSet { updateFontMetrics() }
  }

  private func updateFontMetrics() {
    // Calculate monospace character width and line height once
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let size = ("M" as NSString).size(withAttributes: attrs)
    charWidth = size.width
    lineHeight = ceil(size.height)
    recalculateTotalHeight()
    needsDisplay = true
  }

  var timestampFont: NSFont {
    // Cap timestamp font size to ensure it fits in gutter
    // "HH:mm:ss" = 8 chars, need ~8 * charWidth + padding to fit in gutterWidth
    let maxTimestampFontSize: CGFloat = 12
    return NSFont.monospacedSystemFont(
      ofSize: min(font.pointSize, maxTimestampFontSize), weight: .regular)
  }

  // MARK: - Data

  private(set) var lines: [OutputLine] = []
  private var totalContentHeight: CGFloat = 0

  // Monospace font metrics (calculated once)
  private var charWidth: CGFloat = 7.2
  private var lineHeight: CGFloat = 16

  // Cache for attributed strings (only for visible lines)
  private var attrStringCache: [UUID: NSAttributedString] = [:]
  private var cacheFont: NSFont?

  // Cache for measured heights (keyed by line ID and content width)
  private var heightCache: [UUID: (width: CGFloat, height: CGFloat)] = [:]
  private var cacheWidth: CGFloat = 0
  private var cachedHeightSum: CGFloat = 0  // Running sum of measured heights for O(1) total
  private var heightUpdatePending: Bool = false  // Track if we need to update after draw

  // Callbacks
  var onSelectionChanged: ((TextSelection?) -> Void)?
  var onLineSelectionChanged: ((Set<Int>) -> Void)?
  var onHeightChanged: (() -> Void)?  // Called when content height changes significantly
  var onClicked: (() -> Void)?  // Called when view is clicked (for focus)

  // MARK: - Selection State

  private var textSelection: TextSelection?
  private var selectedLineIndices: Set<Int> = []
  private var isSelectingLines: Bool = false  // True when dragging in gutter
  private var selectionAnchorLine: Int?

  // Mouse tracking
  private var isDragging: Bool = false
  private var dragStartPoint: NSPoint?
  private var dragStartLine: Int?
  private var dragStartChar: Int?

  // MARK: - Timestamp Formatting

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  // MARK: - Initialization

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    postsFrameChangedNotifications = true
    updateFontMetrics()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Observe scroll events to force full redraws (prevents timestamp artifacts)
    if let clipView = enclosingScrollView?.contentView {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrollViewDidScroll(_:)),
        name: NSView.boundsDidChangeNotification,
        object: clipView
      )
    }
  }

  @objc private func scrollViewDidScroll(_ notification: Notification) {
    // Force redraw of entire visible rect to prevent timestamp artifacts
    setNeedsDisplay(visibleRect)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if let scrollView = enclosingScrollView {
      // Size to scroll view width
      let width = scrollView.contentView.bounds.width
      if width > 0 {
        frame = NSRect(x: 0, y: 0, width: width, height: frame.height)
        invalidateAllLayouts()
        recalculateTotalHeight()
      }
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(newSize.width - bounds.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged {
      // Width changed - cache will be invalidated in measuredHeight()
      // Just trigger recalculation and redraw
      recalculateTotalHeight()
      needsDisplay = true
    }
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    // After resize ends, invalidate layouts to get proper wrapping
    invalidateAllLayouts()
    needsDisplay = true
  }

  // MARK: - Public API

  func setLines(_ newLines: [OutputLine]) {
    // Remove cached heights for lines that no longer exist
    let newIds = Set(newLines.map { $0.id })
    var heightChanged = false
    for (id, cached) in heightCache {
      if !newIds.contains(id) {
        cachedHeightSum -= cached.height + lineSpacing
        heightChanged = true
      }
    }
    heightCache = heightCache.filter { newIds.contains($0.key) }
    cachedHeightSum = max(0, cachedHeightSum)  // Safety: ensure non-negative
    
    // Remove cached attributed strings for lines that no longer exist
    attrStringCache = attrStringCache.filter { newIds.contains($0.key) }

    lines = newLines
    if heightChanged {
      heightUpdatePending = true
    }
    recalculateTotalHeight()
    needsDisplay = true
  }

  func appendLine(_ line: OutputLine) {
    lines.append(line)
    recalculateTotalHeight()
    needsDisplay = true
  }

  func appendLines(_ newLines: [OutputLine]) {
    lines.append(contentsOf: newLines)
    recalculateTotalHeight()
    needsDisplay = true
  }

  /// Get attributed string for a line (cached, lazy conversion)
  private func attributedString(for line: OutputLine) -> NSAttributedString {
    // Invalidate cache if font changed
    if cacheFont !== font {
      attrStringCache.removeAll()
      cacheFont = font
    }

    if let cached = attrStringCache[line.id] {
      return cached
    }

    let attrString = buildAttributedString(for: line)
    attrStringCache[line.id] = attrString
    return attrString
  }

  private func buildAttributedString(for line: OutputLine) -> NSAttributedString {
    // Meta lines (started, stopped, etc.) get special styling
    if line.isMeta {
      let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      let color: NSColor
      switch line.kind {
      case .started:
        color = NSColor.systemGreen.withAlphaComponent(0.8)
      case .stopped:
        color = NSColor.systemGray
      case .failed:
        color = NSColor.systemRed.withAlphaComponent(0.8)
      case .info:
        color = NSColor.systemBlue.withAlphaComponent(0.8)
      case .output:
        color = NSColor.secondaryLabelColor
      }
      let attrs: [NSAttributedString.Key: Any] = [
        .font: italicFont,
        .foregroundColor: color,
      ]
      return NSAttributedString(string: line.rawText, attributes: attrs)
    }

    let attrString = NSMutableAttributedString()

    for segment in line.segments {
      switch segment {
      case .text(let text, let style):
        var attrs: [NSAttributedString.Key: Any] = [.font: font]

        if let fg = style.foreground {
          attrs[.foregroundColor] = NSColor(fg)
        } else {
          attrs[.foregroundColor] = NSColor.labelColor
        }

        if let bg = style.background {
          attrs[.backgroundColor] = NSColor(bg)
        }

        if style.bold {
          attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }

        if style.italic {
          attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        if style.underline {
          attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        if style.dim {
          attrs[.foregroundColor] = NSColor.secondaryLabelColor
        }

        attrString.append(NSAttributedString(string: text, attributes: attrs))

      case .nonPrintable(let name):
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.75, weight: .medium),
          .foregroundColor: NSColor.secondaryLabelColor,
          .backgroundColor: NSColor.quaternaryLabelColor,
        ]
        attrString.append(NSAttributedString(string: " \(name) ", attributes: attrs))
      }
    }

    return attrString
  }

  func clearSelection() {
    textSelection = nil
    selectedLineIndices.removeAll()
    needsDisplay = true
  }

  func getSelectedText() -> String? {
    // First check line selection - use raw text to preserve ANSI codes
    if !selectedLineIndices.isEmpty {
      let sortedIndices = selectedLineIndices.sorted()
      return sortedIndices.map { lines[$0].rawText }.joined(separator: "\n")
    }

    // Then check text selection - use visible text (char indices are based on attributed string)
    guard let sel = textSelection?.normalized, !sel.isEmpty else { return nil }

    var result = ""
    for lineIdx in sel.startLine...sel.endLine {
      guard lineIdx < lines.count else { continue }
      let line = lines[lineIdx]
      let attrString = attributedString(for: line)
      let text = attrString.string

      let start = (lineIdx == sel.startLine) ? sel.startChar : 0
      let end = (lineIdx == sel.endLine) ? sel.endChar : text.count

      let startIndex = text.index(text.startIndex, offsetBy: min(start, text.count))
      let endIndex = text.index(text.startIndex, offsetBy: min(end, text.count))

      if lineIdx > sel.startLine { result += "\n" }
      result += String(text[startIndex..<endIndex])
    }
    return result.isEmpty ? nil : result
  }

  // MARK: - Layout

  func invalidateAllLayouts() {
    // Clear height cache so measurements are recalculated
    heightCache.removeAll()
    cachedHeightSum = 0
    heightUpdatePending = false
  }

  /// Measure all line heights to get accurate total (O(n), use sparingly)
  func measureAllHeights() {
    let contentWidth = bounds.width - gutterWidth - contentPadding * 2
    guard contentWidth > 0 else { return }

    for line in lines {
      // Use fast measurement if possible, falling back to slow measure for complex lines
      if let fastHeight = fastMeasureHeight(for: line, contentWidth: contentWidth) {
        // Manually cache the fast result
        heightCache[line.id] = (contentWidth, fastHeight)
        cachedHeightSum += fastHeight + lineSpacing
      } else {
        _ = measuredHeight(for: line, contentWidth: contentWidth)
      }
    }
    recalculateTotalHeight()
  }

  /// Fast arithmetic measurement for simple lines (no wrapping, no special chars)
  private func fastMeasureHeight(for line: OutputLine, contentWidth: CGFloat) -> CGFloat? {
    // 1. Check strict length limit (including invisible ANSI codes)
    // If raw length fits, the visual length (shorter due to ANSI) definitely fits
    // UNLESS there are expanding non-printables
    guard CGFloat(line.rawText.count) * charWidth <= contentWidth else { return nil }

    // 2. Check for expanding control characters (ASCII < 32, except TAB/LF)
    // These render as badges (e.g. [NUL]) which are wider than 1 char
    for scalar in line.rawText.unicodeScalars {
      let v = scalar.value
      // Check for control chars that expand (exclude tab/newline which we handle or ignore)
      if v < 32 && v != 9 && v != 10 {
        return nil
      }
    }

    // Safe to assume single line height
    return lineHeight
  }

  func recalculateTotalHeight() {
    let width = bounds.width > 0 ? bounds.width : (superview?.bounds.width ?? 400)

    // O(1) calculation: use actual heights for measured lines, estimate for the rest
    let measuredCount = heightCache.count
    let unmeasuredCount = max(0, lines.count - measuredCount)
    let estimateForUnmeasured = CGFloat(unmeasuredCount) * (lineHeight + lineSpacing)
    totalContentHeight = contentPadding * 2 + cachedHeightSum + estimateForUnmeasured

    // Update frame to match content
    let minHeight = superview?.bounds.height ?? 100
    let newFrame = NSRect(x: 0, y: 0, width: width, height: max(totalContentHeight, minHeight))
    if abs(frame.size.height - newFrame.size.height) > 1
      || abs(frame.size.width - newFrame.size.width) > 1
    {
      frame = newFrame
      // Notify scroll view of size change
      if let scrollView = enclosingScrollView {
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
    }
  }

  /// Get actual rendered height for a line (cached)
  private func measuredHeight(for line: OutputLine, contentWidth: CGFloat) -> CGFloat {
    // Invalidate cache if width changed significantly
    if abs(cacheWidth - contentWidth) > 1 {
      heightCache.removeAll()
      cachedHeightSum = 0
      cacheWidth = contentWidth
      heightUpdatePending = false  // Reset since we're starting fresh
    }

    // Check cache
    if let cached = heightCache[line.id], abs(cached.width - contentWidth) < 1 {
      return cached.height
    }

    // Try fast measurement first
    if let fastHeight = fastMeasureHeight(for: line, contentWidth: contentWidth) {
      heightCache[line.id] = (contentWidth, fastHeight)
      cachedHeightSum += fastHeight + lineSpacing
      heightUpdatePending = true
      return fastHeight
    }

    // Measure
    let attrString = attributedString(for: line)
    guard attrString.length > 0, contentWidth > 0 else { return lineHeight }
    let rect = attrString.boundingRect(
      with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let height = max(lineHeight, ceil(rect.height))

    // Cache result and update running sum
    heightCache[line.id] = (contentWidth, height)
    cachedHeightSum += height + lineSpacing
    heightUpdatePending = true  // Signal that total height may need updating
    return height
  }

  // MARK: - Drawing

  override var isFlipped: Bool { true }  // Use top-left origin

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Don't draw content until initial scroll completes
    if suppressDrawing { return }

    // Background
    context.setFillColor(NSColor.textBackgroundColor.cgColor)
    context.fill(dirtyRect)

    // Draw gutter background
    let gutterRect = NSRect(x: 0, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height)
    context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor)
    context.fill(gutterRect)

    let contentWidth = bounds.width - gutterWidth - contentPadding * 2
    guard contentWidth > 0, !lines.isEmpty else { return }

    // Find visible line range using estimation
    let visibleRect = self.visibleRect
    let (startLine, startY) = findStartLine(in: visibleRect, contentWidth: contentWidth)

    // Draw visible lines, tracking Y position as we go
    var y = startY
    var lastTimestamp: String?
    let contentX = gutterWidth + contentPadding

    for lineIndex in startLine..<lines.count {
      // Stop if past visible area
      if y > visibleRect.maxY + 100 { break }

      let line = lines[lineIndex]

      // Get height (cached) and attributed string (cached)
      let height = measuredHeight(for: line, contentWidth: contentWidth)
      let attrString = attributedString(for: line)
      let lineBounds = CGRect(x: contentX, y: y, width: contentWidth, height: height)

      // Draw selection background
      drawSelectionBackground(for: lineIndex, bounds: lineBounds, in: context)

      // Draw gutter (timestamp)
      let timestamp = Self.timestampFormatter.string(from: line.timestamp)
      let showTimestamp = (timestamp != lastTimestamp)
      lastTimestamp = timestamp
      drawGutter(
        timestamp: showTimestamp ? timestamp : nil,
        isLineSelected: selectedLineIndices.contains(lineIndex),
        at: y,
        height: height,
        in: context)

      // Draw content
      attrString.draw(
        with: lineBounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

      y += height + lineSpacing
    }

    // After drawing, update total height if new lines were measured
    // Must defer to avoid changing frame during draw
    if heightUpdatePending {
      heightUpdatePending = false
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        let oldHeight = self.frame.height
        self.recalculateTotalHeight()
        // If height changed significantly, notify scroll view and callback
        if abs(self.frame.height - oldHeight) > 1 {
          self.enclosingScrollView?.reflectScrolledClipView(self.enclosingScrollView!.contentView)
          self.onHeightChanged?()
        }
      }
    }
  }

  /// Find the first visible line by iterating through lines
  private func findStartLine(in rect: NSRect, contentWidth: CGFloat) -> (Int, CGFloat) {
    guard !lines.isEmpty else { return (0, contentPadding) }

    var y: CGFloat = contentPadding

    for i in 0..<lines.count {
      let height = measuredHeight(for: lines[i], contentWidth: contentWidth)

      // If this line's bottom is past the visible rect top, start here
      if y + height >= rect.minY {
        return (i, y)
      }
      y += height + lineSpacing
    }

    return (lines.count - 1, y)
  }

  private func drawGutter(
    timestamp: String?, isLineSelected: Bool, at y: CGFloat, height: CGFloat, in context: CGContext
  ) {
    // Always clear the gutter area for this line to prevent scroll artifacts
    let gutterLineRect = CGRect(x: 0, y: y, width: gutterWidth, height: height + lineSpacing)
    context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor)
    context.fill(gutterLineRect)

    // Highlight if line is selected
    if isLineSelected {
      context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.3).cgColor)
      context.fill(CGRect(x: 0, y: y, width: gutterWidth, height: height))
    }

    guard let timestamp = timestamp else { return }

    let attrs: [NSAttributedString.Key: Any] = [
      .font: timestampFont,
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6),
    ]

    let attrString = NSAttributedString(string: timestamp, attributes: attrs)
    let size = attrString.size()

    // Right-align in gutter
    let x = gutterWidth - size.width - 8
    let textY = y + (height - size.height) / 2

    attrString.draw(at: NSPoint(x: x, y: textY))
  }

  private func drawSelectionBackground(
    for lineIndex: Int, bounds lineBounds: CGRect, in context: CGContext
  ) {
    // Check line selection
    if selectedLineIndices.contains(lineIndex) {
      context.setFillColor(NSColor.selectedTextBackgroundColor.cgColor)
      let rect = CGRect(
        x: gutterWidth, y: lineBounds.minY,
        width: self.bounds.width - gutterWidth, height: lineBounds.height)
      context.fill(rect)
      return
    }

    // Check text selection - highlight entire line if in selection range
    guard let sel = textSelection?.normalized else { return }
    guard lineIndex >= sel.startLine && lineIndex <= sel.endLine else { return }

    context.setFillColor(NSColor.selectedTextBackgroundColor.cgColor)
    context.fill(lineBounds)
  }

  // MARK: - Hit Testing

  /// Find line and Y bounds at a point, accounting for wrapped lines
  private func lineIndexAndBounds(at point: NSPoint) -> (
    lineIndex: Int, yStart: CGFloat, height: CGFloat
  )? {
    guard !lines.isEmpty else { return nil }

    let contentWidth = bounds.width - gutterWidth - contentPadding * 2
    guard contentWidth > 0 else { return nil }

    // Must iterate from beginning to get accurate Y positions with variable heights
    var y: CGFloat = contentPadding

    for i in 0..<lines.count {
      let height = measuredHeight(for: lines[i], contentWidth: contentWidth)
      if point.y >= y && point.y < y + height + lineSpacing {
        return (i, y, height)
      }
      y += height + lineSpacing
    }

    // Point is below all lines - return last line
    if !lines.isEmpty {
      let lastHeight = measuredHeight(for: lines.last!, contentWidth: contentWidth)
      return (lines.count - 1, y - lastHeight - lineSpacing, lastHeight)
    }

    return nil
  }

  private func lineIndex(at point: NSPoint) -> Int? {
    return lineIndexAndBounds(at: point)?.lineIndex
  }

  private func charIndex(at point: NSPoint, in lineIndex: Int, lineYStart: CGFloat? = nil) -> Int {
    guard lineIndex < lines.count else { return 0 }

    let line = lines[lineIndex]
    let attrString = attributedString(for: line)
    let text = attrString.string
    guard !text.isEmpty else { return 0 }

    let contentWidth = bounds.width - gutterWidth - contentPadding * 2
    let localX = max(0, point.x - gutterWidth - contentPadding)

    // Calculate which visual row within a wrapped line
    let yInLine = lineYStart.map { max(0, point.y - $0) } ?? 0
    let visualRow = Int(yInLine / lineHeight)

    // Estimate characters per visual row based on content width
    let charsPerRow = max(1, Int(contentWidth / charWidth))

    // Character position: row * chars_per_row + chars in current row
    let charInRow = Int(localX / charWidth)
    let totalChar = visualRow * charsPerRow + charInRow

    return max(0, min(totalChar, text.count))
  }

  private func isInGutter(_ point: NSPoint) -> Bool {
    point.x < gutterWidth
  }

  // MARK: - Mouse Handling

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)

    window?.makeFirstResponder(self)

    // Notify parent that view was clicked (for focus)
    onClicked?()

    if isInGutter(point) {
      // Gutter click - line selection
      handleGutterMouseDown(at: point, event: event)
    } else {
      // Content click - text selection
      handleContentMouseDown(at: point, event: event)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)

    if isSelectingLines {
      handleGutterMouseDragged(at: point)
    } else if isDragging {
      handleContentMouseDragged(at: point)
    }
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false
    isSelectingLines = false
    dragStartPoint = nil
  }

  private func handleGutterMouseDown(at point: NSPoint, event: NSEvent) {
    guard let lineIdx = lineIndex(at: point) else { return }

    isSelectingLines = true
    selectionAnchorLine = lineIdx
    textSelection = nil  // Clear text selection

    if event.modifierFlags.contains(.shift), let anchor = selectionAnchorLine {
      // Extend selection
      let range = min(anchor, lineIdx)...max(anchor, lineIdx)
      selectedLineIndices = Set(range)
    } else if event.modifierFlags.contains(.command) {
      // Toggle
      if selectedLineIndices.contains(lineIdx) {
        selectedLineIndices.remove(lineIdx)
      } else {
        selectedLineIndices.insert(lineIdx)
      }
      selectionAnchorLine = lineIdx
    } else {
      // Single selection
      selectedLineIndices = [lineIdx]
      selectionAnchorLine = lineIdx
    }

    onLineSelectionChanged?(selectedLineIndices)
    needsDisplay = true
  }

  private func handleGutterMouseDragged(at point: NSPoint) {
    guard let anchor = selectionAnchorLine,
      let lineIdx = lineIndex(at: point)
    else { return }

    let range = min(anchor, lineIdx)...max(anchor, lineIdx)
    selectedLineIndices = Set(range)
    onLineSelectionChanged?(selectedLineIndices)
    needsDisplay = true
  }

  private func handleContentMouseDown(at point: NSPoint, event: NSEvent) {
    guard let result = lineIndexAndBounds(at: point) else { return }
    let lineIdx = result.lineIndex

    isDragging = true
    dragStartPoint = point
    dragStartLine = lineIdx
    dragStartChar = charIndex(at: point, in: lineIdx, lineYStart: result.yStart)

    if event.clickCount == 2 {
      // Double-click: select word
      selectedLineIndices.removeAll()
      selectWord(at: point, in: lineIdx, lineYStart: result.yStart)
    } else if event.clickCount >= 3 {
      // Triple-click: select line (same as single click, but explicit)
      textSelection = nil
      selectedLineIndices = [lineIdx]
      selectionAnchorLine = lineIdx
    } else {
      // Single click: select line (consistent with gutter click)
      textSelection = nil
      selectedLineIndices = [lineIdx]
      selectionAnchorLine = lineIdx
    }

    onSelectionChanged?(textSelection)
    onLineSelectionChanged?(selectedLineIndices)
    needsDisplay = true
  }

  private func handleContentMouseDragged(at point: NSPoint) {
    guard let anchor = selectionAnchorLine else { return }

    let result = lineIndexAndBounds(at: point)
    let lineIdx = result?.lineIndex ?? (point.y < 0 ? 0 : lines.count - 1)

    // Extend line selection (consistent with gutter drag)
    let range = min(anchor, lineIdx)...max(anchor, lineIdx)
    selectedLineIndices = Set(range)

    onLineSelectionChanged?(selectedLineIndices)
    needsDisplay = true

    // Auto-scroll if near edges
    autoScrollIfNeeded(point: point)
  }

  private func selectWord(at point: NSPoint, in lineIndex: Int, lineYStart: CGFloat? = nil) {
    let line = lines[lineIndex]
    let attrString = attributedString(for: line)
    let text = attrString.string
    let charIdx = charIndex(at: point, in: lineIndex, lineYStart: lineYStart)

    // Find word boundaries
    var start = charIdx
    var end = charIdx

    let chars = Array(text)
    guard !chars.isEmpty else { return }

    while start > 0 && !chars[start - 1].isWhitespace {
      start -= 1
    }
    while end < chars.count && !chars[end].isWhitespace {
      end += 1
    }

    textSelection = TextSelection(
      startLine: lineIndex,
      startChar: start,
      endLine: lineIndex,
      endChar: end
    )
  }

  private func autoScrollIfNeeded(point: NSPoint) {
    guard let scrollView = enclosingScrollView else { return }
    let visible = scrollView.contentView.bounds

    var scrollDelta: CGFloat = 0
    if point.y < visible.minY + 20 {
      scrollDelta = -20
    } else if point.y > visible.maxY - 20 {
      scrollDelta = 20
    }

    if scrollDelta != 0 {
      let newOrigin = CGPoint(x: visible.origin.x, y: visible.origin.y + scrollDelta)
      scrollView.contentView.scroll(to: newOrigin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }

  // MARK: - Keyboard & Menu

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
      copy(nil)
    } else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" {
      selectAll(nil)
    } else {
      super.keyDown(with: event)
    }
  }

  @objc func copy(_ sender: Any?) {
    guard let text = getSelectedText() else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  override func selectAll(_ sender: Any?) {
    guard !lines.isEmpty else { return }
    let lastLine = lines.last!
    let lastAttrString = attributedString(for: lastLine)
    textSelection = TextSelection(
      startLine: 0,
      startChar: 0,
      endLine: lines.count - 1,
      endChar: lastAttrString.length
    )
    selectedLineIndices.removeAll()
    needsDisplay = true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()

    let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
    copyItem.target = self
    copyItem.isEnabled = (getSelectedText() != nil)
    menu.addItem(copyItem)

    menu.addItem(NSMenuItem.separator())

    let selectAllItem = NSMenuItem(
      title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
    selectAllItem.target = self
    menu.addItem(selectAllItem)

    // Look Up (if single word selected or word under cursor)
    let point = convert(event.locationInWindow, from: nil)
    if let word = wordUnderPoint(point) {
      menu.addItem(NSMenuItem.separator())
      let lookUpItem = NSMenuItem(
        title: "Look Up \"\(word)\"", action: #selector(lookUpWord(_:)), keyEquivalent: "")
      lookUpItem.target = self
      lookUpItem.representedObject = word
      menu.addItem(lookUpItem)
    }

    return menu
  }

  private func wordUnderPoint(_ point: NSPoint) -> String? {
    guard let result = lineIndexAndBounds(at: point) else { return nil }
    let lineIdx = result.lineIndex
    let line = lines[lineIdx]
    let attrString = attributedString(for: line)
    let text = attrString.string
    let charIdx = charIndex(at: point, in: lineIdx, lineYStart: result.yStart)

    let chars = Array(text)
    guard charIdx < chars.count && !chars[charIdx].isWhitespace else { return nil }

    var start = charIdx
    var end = charIdx

    while start > 0 && !chars[start - 1].isWhitespace {
      start -= 1
    }
    while end < chars.count && !chars[end].isWhitespace {
      end += 1
    }

    let startIndex = text.index(text.startIndex, offsetBy: start)
    let endIndex = text.index(text.startIndex, offsetBy: end)
    return String(text[startIndex..<endIndex])
  }

  @objc func lookUpWord(_ sender: NSMenuItem) {
    guard let word = sender.representedObject as? String else { return }
    NSWorkspace.shared.open(URL(string: "dict://\(word)")!)
  }

  // MARK: - Responder Chain

  override func responds(to aSelector: Selector!) -> Bool {
    if aSelector == #selector(copy(_:)) || aSelector == #selector(selectAll(_:)) {
      return true
    }
    return super.responds(to: aSelector)
  }
}

// MARK: - SwiftUI Bridge

struct LogContentViewRepresentable: NSViewRepresentable {
  let lines: [OutputLine]
  let font: NSFont
  let gutterWidth: CGFloat
  var onClicked: (() -> Void)?

  @Binding var scrollToBottom: Bool
  @Binding var isTailing: Bool

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    let contentView = LogContentView()
    contentView.font = font
    contentView.gutterWidth = gutterWidth
    contentView.onClicked = onClicked
    // Don't set lines yet - wait until view is sized
    // Suppress drawing until initial scroll completes
    contentView.suppressDrawing = !lines.isEmpty

    scrollView.documentView = contentView

    // IMPORTANT: Set references BEFORE registering notifications to avoid race condition
    context.coordinator.documentView = contentView
    context.coordinator.scrollView = scrollView
    context.coordinator.isTailingBinding = _isTailing
    context.coordinator.needsInitialScroll = !lines.isEmpty  // Flag for scroll when sized
    context.coordinator.pendingLines = lines.isEmpty ? nil : lines  // Store for deferred population

    // Set up height change callback - re-scroll when tailing and height grows
    let coordinator = context.coordinator
    contentView.onHeightChanged = { [weak coordinator, weak contentView] in
      guard let coordinator = coordinator,
        let contentView = contentView,
        let scrollView = coordinator.scrollView,
        coordinator.isTailingBinding?.wrappedValue == true
      else { return }

      // Re-scroll to bottom when height changes and we're tailing
      let maxY = contentView.frame.height - scrollView.contentView.bounds.height
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, maxY)))
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // Set up scroll notifications
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.contentView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.scrollViewDidScroll(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.clipViewFrameChanged(_:)),
      name: NSView.frameDidChangeNotification,
      object: scrollView.contentView
    )

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let contentView = scrollView.documentView as? LogContentView else { return }

    contentView.font = font
    contentView.gutterWidth = gutterWidth

    // Update coordinator's reference to isTailing binding
    context.coordinator.isTailingBinding = _isTailing

    // Skip content updates while waiting for initial scroll - prevents visible scrolling
    if context.coordinator.needsInitialScroll {
      return
    }

    let oldCount = contentView.lines.count
    let newCount = lines.count

    // Always ensure proper width first
    let scrollWidth = scrollView.contentView.bounds.width
    if scrollWidth > 0 && abs(contentView.bounds.width - scrollWidth) > 0.5 {
      contentView.frame.size.width = scrollWidth
    }

    // Detect type of change: append, reset, or no change
    if newCount > oldCount && oldCount > 0 {
      // Check if this is a pure append (existing lines unchanged)
      let isAppend = lines[oldCount - 1].id == contentView.lines[oldCount - 1].id
      if isAppend {
        // Efficient append path - O(new lines) not O(all lines)
        let newLines = Array(lines[oldCount...])
        contentView.appendLines(newLines)
      } else {
        // Lines were modified, need full replacement
        contentView.setLines(lines)
      }
    } else if newCount != oldCount
      || (newCount > 0 && lines.first?.id != contentView.lines.first?.id)
    {
      // Full replacement needed
      contentView.setLines(lines)
    }

    // Recalculate height if we have lines and valid width
    if scrollWidth > 0 && !lines.isEmpty {
      contentView.recalculateTotalHeight()
      contentView.needsDisplay = true
    }

    // Scroll to bottom if explicitly requested (user clicked button)
    if scrollToBottom {
      DispatchQueue.main.async {
        self.scrollToBottomIfNeeded(scrollView, measureFirst: true)
        self.scrollToBottom = false
      }
    }
    // Auto-scroll if tailing is enabled and new lines arrived
    else if newCount != oldCount && isTailing {
      // If we went from 0 to N lines (initial async load), scroll IMMEDIATELY to avoid visual jump
      if oldCount == 0 {
        self.scrollToBottomIfNeeded(scrollView, measureFirst: true)
      } else {
        DispatchQueue.main.async {
          self.scrollToBottomIfNeeded(scrollView)
        }
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  private func scrollToBottomIfNeeded(_ scrollView: NSScrollView, measureFirst: Bool = false) {
    guard let contentView = scrollView.documentView as? LogContentView else { return }

    // Only measure all heights on explicit request (e.g., initial load)
    // For auto-scroll during tailing, use current frame height (may not be exact but is fast)
    if measureFirst {
      contentView.measureAllHeights()
    }

    let maxY = contentView.frame.height - scrollView.contentView.bounds.height
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, maxY)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  class Coordinator: NSObject {
    var lastScrollPosition: CGFloat = 0
    weak var documentView: LogContentView?
    weak var scrollView: NSScrollView?
    var isTailingBinding: Binding<Bool>?
    var needsInitialScroll: Bool = false
    var pendingLines: [OutputLine]?  // Lines waiting to be set after view is sized
    private var lastUserScrollTime: Date?

    func isAtBottom(_ scrollView: NSScrollView) -> Bool {
      guard let documentView = scrollView.documentView else { return true }
      let visibleHeight = scrollView.contentView.bounds.height
      let contentHeight = documentView.frame.height
      let scrollPosition = scrollView.contentView.bounds.origin.y
      return scrollPosition >= contentHeight - visibleHeight - 20
    }

    @objc func scrollViewDidScroll(_ notification: Notification) {
      guard let clipView = notification.object as? NSClipView,
        let scrollView = clipView.enclosingScrollView
      else { return }

      // Detect user-initiated scroll (not programmatic)
      // If user scrolls away from bottom, disable tailing
      if !isAtBottom(scrollView) {
        // Only update if we're currently tailing
        if isTailingBinding?.wrappedValue == true {
          DispatchQueue.main.async { [weak self] in
            self?.isTailingBinding?.wrappedValue = false
          }
        }
      }
    }

    @objc func clipViewFrameChanged(_ notification: Notification) {
      guard let clipView = notification.object as? NSClipView,
        let contentView = documentView,
        let scrollView = scrollView
      else { return }
      let newWidth = clipView.bounds.width
      if newWidth > 0 && abs(contentView.bounds.width - newWidth) > 0.5 {
        contentView.frame = NSRect(x: 0, y: 0, width: newWidth, height: contentView.frame.height)
        contentView.recalculateTotalHeight()
        contentView.needsDisplay = true
      }

      // Perform deferred initial population and scroll once we have a valid size
      if needsInitialScroll && clipView.bounds.height > 0 && clipView.bounds.width > 0 {
        needsInitialScroll = false

        // Now populate with lines (view is sized, so heights can be calculated properly)
        if let lines = pendingLines {
          pendingLines = nil
          contentView.frame.size.width = clipView.bounds.width
          contentView.setLines(lines)
          // Force measurement of all lines to ensure accurate height for scrolling
          // This prevents visual jumping/scrolling artifacts on initial load
          contentView.measureAllHeights()
        }

        // Scroll to bottom
        let maxY = contentView.frame.height - clipView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Now allow drawing - we're scrolled to the right position
        contentView.suppressDrawing = false
        contentView.needsDisplay = true
      }
    }
  }
}
