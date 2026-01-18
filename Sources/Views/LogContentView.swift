import AppKit
import CoreText
import SwiftUI

// LogLine and TextSelection types moved to LogLine.swift

extension LogLine {
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

  /// Track resize state - checks custom flag, window's live resize, and cooldown
  var isInLiveResize: Bool {
    if _isInLiveResize || isPanelResizing || (window?.inLiveResize ?? false) {
      return true
    }
    // 500ms cooldown after resize ends
    if let endedAt = resizeEndedAt, Date().timeIntervalSince(endedAt) < 0.5 {
      return true
    }
    return false
  }
  private var _isInLiveResize: Bool = false
  var isPanelResizing: Bool = false  // Set by coordinator during panel resize
  private var resizeEndedAt: Date?

  var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) {
    didSet {
      guard font != oldValue else { return }
      updateFontMetrics()
    }
  }

  /// Regex patterns for highlighting
  var highlightPatterns: [String] = [] {
    didSet {
      guard highlightPatterns != oldValue else { return }
      // Compile regexes and invalidate cache when patterns change
      compiledHighlightPatterns = highlightPatterns.compactMap { pattern in
        try? NSRegularExpression(pattern: pattern, options: [])
      }
      attrStringCache.removeAll()
      needsDisplay = true
    }
  }
  private var compiledHighlightPatterns: [NSRegularExpression] = []

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
  private(set) var lineHeight: CGFloat = 16

  // Cache for attributed strings (only for visible lines)
  private var attrStringCache: [UUID: NSAttributedString] = [:]
  private var cacheFont: NSFont?
  private let maxAttrCacheSize = 5000  // Limit to prevent unbounded growth

  // Cache for measured heights (keyed by line ID and content width)
  private var heightCache: [UUID: (width: CGFloat, height: CGFloat)] = [:]
  private let maxHeightCacheSize = 5000
  private var cacheWidth: CGFloat = 0
  private var cachedHeightSum: CGFloat = 0  // Running sum of measured heights for O(1) total
  private var heightUpdatePending: Bool = false  // Track if we need to update after draw

  // Callbacks
  var onSelectionChanged: ((TextSelection?) -> Void)?
  var onLineSelectionChanged: ((Set<Int>) -> Void)?
  var onHeightChanged: (() -> Void)?  // Called when content height changes significantly
  var onClicked: (() -> Void)?  // Called when view is clicked (for focus)
  var onResizeStateChanged: ((Bool) -> Void)?  // Called when resize starts/ends (true = resizing)
  var onDebugDump: (() -> String)?  // Called to get coordinator debug info

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

  var savedTopLineForWindowResize: Int?

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    _isInLiveResize = true
    // Save which line is at top so we can restore after resize
    savedTopLineForWindowResize = topVisibleLineIndex()
    // Notify coordinator to disable tailing
    onResizeStateChanged?(true)
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    _isInLiveResize = false
    // Invalidate height cache since width changed - this enables proper wrapping
    invalidateAllLayouts()
    // Measure all lines to get accurate total height (prevents scroll bounds issues)
    measureAllHeights()
    // Start cooldown AFTER height calculation so recalculateTotalHeight() runs
    resizeEndedAt = Date()
    needsDisplay = true

    // Restore scroll position to keep same line at top
    if let savedLine = savedTopLineForWindowResize {
      scrollToLine(savedLine)
      savedTopLineForWindowResize = nil
    }

    // Notify coordinator resize ended (with delay to let scroll settle)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.onResizeStateChanged?(false)
    }
  }

  /// Called by coordinator when rapid resizing stops
  func handleResizeEnded() {
    _isInLiveResize = false
    // Invalidate height cache since width changed - this enables proper wrapping
    invalidateAllLayouts()
    // Measure all lines to get accurate total height (prevents scroll bounds issues)
    measureAllHeights()
    // Start cooldown AFTER height calculation so recalculateTotalHeight() runs
    resizeEndedAt = Date()
    needsDisplay = true
  }

  /// Get the index of the line currently at the top of the visible area
  func topVisibleLineIndex() -> Int {
    guard !lines.isEmpty else { return 0 }
    let visibleRect = self.visibleRect
    let contentWidth = bounds.width - gutterWidth - contentPadding * 2
    guard contentWidth > 0 else { return 0 }

    // Use estimation (O(1)) - good enough for saving position
    let estimatedLineHeight = lineHeight + lineSpacing
    let estimatedLine = max(0, Int((visibleRect.minY - contentPadding) / estimatedLineHeight))
    return min(estimatedLine, lines.count - 1)
  }

  /// Scroll to position a specific line at the top of the visible area
  func scrollToLine(_ lineIndex: Int) {
    guard lineIndex >= 0, lineIndex < lines.count else { return }
    guard let scrollView = enclosingScrollView else { return }

    // Calculate Y position for this line (using estimation for speed)
    let estimatedLineHeight = lineHeight + lineSpacing
    let targetY = contentPadding + CGFloat(lineIndex) * estimatedLineHeight

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
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

    // Evict old entries if cache is too large
    if attrStringCache.count >= maxAttrCacheSize {
      // Remove ~20% of entries (arbitrary keys since dict is unordered)
      let keysToRemove = Array(attrStringCache.keys.prefix(maxAttrCacheSize / 5))
      for key in keysToRemove {
        attrStringCache.removeValue(forKey: key)
      }
    }

    attrStringCache[line.id] = attrString
    return attrString
  }

  private func buildAttributedString(for line: OutputLine) -> NSAttributedString {
    let isLightMode = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua

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
      return NSAttributedString(string: "● " + line.rawText, attributes: attrs)
    }

    let attrString = NSMutableAttributedString()

    for segment in line.segments {
      switch segment {
      case .text(let text, let style):
        var attrs: [NSAttributedString.Key: Any] = [.font: font]

        if let fg = style.foreground {
          var color = NSColor(fg)
          // In light mode, standard ANSI bright colors (yellow, cyan, etc.) are often illegible
          // Darken them significantly to ensure contrast
          if isLightMode {
            color = color.blended(withFraction: 0.3, of: .black) ?? color
          }
          attrs[.foregroundColor] = color
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

    // Apply highlight patterns
    applyHighlighting(to: attrString)

    return attrString
  }

  /// Apply highlight background to all regex matches in the attributed string
  private func applyHighlighting(to attrString: NSMutableAttributedString) {
    guard !compiledHighlightPatterns.isEmpty else { return }

    let text = attrString.string
    let fullRange = NSRange(location: 0, length: text.utf16.count)

    // Bright highlight color - yellow with high visibility
    let highlightColor = NSColor.systemYellow.withAlphaComponent(0.7)
    // Use black text for contrast on yellow background
    let highlightTextColor = NSColor.black

    for regex in compiledHighlightPatterns {
      let matches = regex.matches(in: text, options: [], range: fullRange)
      for match in matches {
        attrString.addAttribute(.backgroundColor, value: highlightColor, range: match.range)
        attrString.addAttribute(.foregroundColor, value: highlightTextColor, range: match.range)
      }
    }
  }

  func clearSelection() {
    textSelection = nil
    selectedLineIndices.removeAll()
    needsDisplay = true
  }

  func getSelectedText() -> String? {
    // First check line selection - use raw text to preserve ANSI codes
    if !selectedLineIndices.isEmpty {
      let sortedIndices = selectedLineIndices.sorted().filter { $0 < lines.count }
      guard !sortedIndices.isEmpty else { return nil }
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
    cacheWidth = 0  // Reset so next measurement uses fresh width
    heightUpdatePending = false
  }

  /// Measure all line heights to get accurate total (O(n), use sparingly)
  func measureAllHeights() {
    let contentWidth = bounds.width - gutterWidth - contentPadding * 2
    guard contentWidth > 0 else { return }

    // Set cacheWidth FIRST to prevent measuredHeight() from clearing the cache mid-iteration
    cacheWidth = contentWidth

    for line in lines {
      // Use fast measurement if possible, falling back to slow measure for complex lines
      if let fastHeight = fastMeasureHeight(for: line, contentWidth: contentWidth) {
        updateCache(for: line.id, width: contentWidth, height: fastHeight)
      } else {
        _ = measuredHeight(for: line, contentWidth: contentWidth)
      }
    }
    recalculateTotalHeight()
  }

  /// Update the height cache for a line, handling subtraction of old value to prevent drift
  private func updateCache(for lineId: UUID, width: CGFloat, height: CGFloat) {
    if let old = heightCache[lineId] {
      cachedHeightSum -= old.height + lineSpacing
    }

    // Evict old entries if cache is too large
    if heightCache.count >= maxHeightCacheSize {
      // Remove ~20% of entries and their height contributions
      let keysToRemove = Array(heightCache.keys.prefix(maxHeightCacheSize / 5))
      for key in keysToRemove {
        if let old = heightCache[key] {
          cachedHeightSum -= old.height + lineSpacing
        }
        heightCache.removeValue(forKey: key)
      }
    }

    heightCache[lineId] = (width, height)
    cachedHeightSum += height + lineSpacing
    heightUpdatePending = true
  }

  /// Fast arithmetic measurement with word wrapping for monospace font
  /// Returns nil only for lines with badge characters (NUL, etc.) that render wider than 1 char
  private func fastMeasureHeight(for line: OutputLine, contentWidth: CGFloat) -> CGFloat? {
    let text = line.plainText
    guard !text.isEmpty else { return lineHeight }

    let maxCol = max(1, Int(floor(contentWidth / charWidth)))

    // Word-wrap calculation using UTF-8 bytes for speed
    // Iterating over Character (grapheme clusters) is extremely slow for bridged NSStrings
    var lines = 1
    var col = 0
    var wordLen = 0

    for byte in text.utf8 {
      // Skip UTF-8 continuation bytes (10xxxxxx) - they're part of multi-byte chars
      if byte & 0xC0 == 0x80 {
        continue
      }

      // Check for badge-rendering control chars (reject line)
      if byte < 32 && byte != 10 && byte != 9 {
        return nil
      }

      if byte == 0x0A {  // newline
        col += wordLen
        wordLen = 0
        lines += 1
        col = 0
      } else if byte == 0x09 {  // tab
        if col + wordLen > maxCol && col > 0 {
          lines += 1
          col = wordLen
        } else {
          col += wordLen
        }
        wordLen = 0
        let nextTab = ((col / 8) + 1) * 8
        if nextTab > maxCol {
          lines += 1
          col = 0
        } else {
          col = nextTab
        }
      } else if byte == 0x20 {  // space
        if col + wordLen > maxCol && col > 0 {
          lines += 1
          col = wordLen
        } else {
          col += wordLen
        }
        wordLen = 0
        col += 1
        if col > maxCol {
          lines += 1
          col = 0
        }
      } else {
        // Regular char (ASCII or UTF-8 lead byte) - add to current word
        wordLen += 1
        if wordLen > maxCol {
          if col > 0 {
            lines += 1
            col = 0
          }
          lines += 1
          wordLen = 1
        }
      }
    }

    // Flush final word
    if wordLen > 0 && col + wordLen > maxCol && col > 0 {
      lines += 1
    }

    return CGFloat(lines) * lineHeight
  }

  func recalculateTotalHeight() {
    // Track if we're resizing to skip scroll reflection (avoids scroll jumping)
    let inResize = isInLiveResize

    let width = bounds.width > 0 ? bounds.width : (superview?.bounds.width ?? 400)
    let contentWidth = width - gutterWidth - contentPadding * 2

    guard !lines.isEmpty, contentWidth > 0 else {
      totalContentHeight = contentPadding * 2
      return
    }

    // Calculate actual height by summing measured heights
    // Use cached heights if they were measured at a similar width (within 50px)
    // This matches the global cache invalidation tolerance and avoids constant re-estimation
    // when width changes slightly (e.g., scrollbar appearing/disappearing)
    var sumOfHeights: CGFloat = 0
    var measuredCount = 0
    var estimatedCount = 0
    for line in lines {
      if let cached = heightCache[line.id], abs(cached.width - contentWidth) <= 50 {
        sumOfHeights += cached.height
        measuredCount += 1
      } else {
        sumOfHeights += lineHeight
        estimatedCount += 1
      }
    }

    // Total = top padding + sum of heights + spacing between lines + bottom padding
    // Spacing is between lines, so (N-1) spacings for N lines
    let spacingTotal = CGFloat(max(0, lines.count - 1)) * lineSpacing
    totalContentHeight = contentPadding + sumOfHeights + spacingTotal + contentPadding

    // Update frame to match content
    let minHeight = superview?.bounds.height ?? 100
    let newFrame = NSRect(x: 0, y: 0, width: width, height: max(totalContentHeight, minHeight))
    if abs(frame.size.height - newFrame.size.height) > 1
      || abs(frame.size.width - newFrame.size.width) > 1
    {
      frame = newFrame
      // Only update scroll view when NOT resizing - reflectScrolledClipView can cause scroll jumping
      if !inResize, let scrollView = enclosingScrollView {
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
    }
  }

  /// Get actual rendered height for a line (cached)
  private func measuredHeight(for line: OutputLine, contentWidth: CGFloat) -> CGFloat {
    // Invalidate cache if width changed significantly (> 50px)
    // Small width changes during frame settling shouldn't invalidate measurements
    if abs(cacheWidth - contentWidth) > 50 {
      heightCache.removeAll()
      cachedHeightSum = 0
      cacheWidth = contentWidth
      heightUpdatePending = false  // Reset since we're starting fresh
    } else if cacheWidth == 0 {
      // First measurement - just set the width
      cacheWidth = contentWidth
    }

    // Check cache - use 50px tolerance to match recalculateTotalHeight()
    // This avoids constant re-measurement during minor width changes (scrollbar, layout)
    if let cached = heightCache[line.id], abs(cached.width - contentWidth) <= 50 {
      return cached.height
    }

    // Try fast measurement first
    if let fastHeight = fastMeasureHeight(for: line, contentWidth: contentWidth) {
      updateCache(for: line.id, width: contentWidth, height: fastHeight)
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
    updateCache(for: line.id, width: contentWidth, height: height)
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

      // Draw meta background
      if line.isMeta {
        drawMetaBackground(at: y, height: height, in: context)
      }

      // Draw selection background
      drawSelectionBackground(for: lineIndex, bounds: lineBounds, in: context)

      // Draw gutter (timestamp)
      let timestamp = Self.timestampFormatter.string(from: line.timestamp)
      let showTimestamp = (timestamp != lastTimestamp)
      lastTimestamp = timestamp
      drawGutter(
        timestamp: showTimestamp ? timestamp : nil,
        isLineSelected: selectedLineIndices.contains(lineIndex),
        isMeta: line.isMeta,
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
    // Skip during live resize to prevent scroll jumping
    if heightUpdatePending && !isInLiveResize {
      heightUpdatePending = false
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.isInLiveResize else { return }
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

  /// Find the first visible line by calculating actual Y positions from cached heights
  /// This ensures correct positioning even with wrapped lines
  private func findStartLine(in rect: NSRect, contentWidth: CGFloat) -> (Int, CGFloat) {
    guard !lines.isEmpty else { return (0, contentPadding) }

    // Calculate actual Y positions using cached heights
    // This is O(n) but necessary for correct scroll positioning with wrapped lines
    var y = contentPadding
    let targetY = rect.minY

    for (index, line) in lines.enumerated() {
      // Get height from cache, or estimate if not cached
      let height: CGFloat
      if let cached = heightCache[line.id], abs(cached.width - contentWidth) <= 50 {
        height = cached.height
      } else {
        height = lineHeight
      }

      // Check if this line starts at or before the target Y
      // Return a few lines earlier to ensure we don't miss any visible content
      if y + height + lineSpacing >= targetY {
        let startIndex = max(0, index - 3)
        // Recalculate Y for the adjusted start index
        var startY = contentPadding
        for i in 0..<startIndex {
          if let cached = heightCache[lines[i].id], abs(cached.width - contentWidth) <= 50 {
            startY += cached.height + lineSpacing
          } else {
            startY += lineHeight + lineSpacing
          }
        }
        return (startIndex, startY)
      }

      y += height + lineSpacing
    }

    // If we reach here, target is past all content - return last line
    return (lines.count - 1, y - lineHeight - lineSpacing)
  }

  private func drawGutter(
    timestamp: String?, isLineSelected: Bool, isMeta: Bool, at y: CGFloat, height: CGFloat,
    in context: CGContext
  ) {
    // Always clear the gutter area for this line to prevent scroll artifacts
    // Skip if it's a meta line as it has its own prominent background
    if !isMeta {
      let gutterLineRect = CGRect(x: 0, y: y, width: gutterWidth, height: height + lineSpacing)
      context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor)
      context.fill(gutterLineRect)
    }

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

  private func drawMetaBackground(at y: CGFloat, height: CGFloat, in context: CGContext) {
    // Subtle background for meta lines - extends across full width including timestamp
    context.setFillColor(NSColor.labelColor.withAlphaComponent(0.06).cgColor)
    let rect = CGRect(
      x: 0, y: y,
      width: self.bounds.width, height: height + lineSpacing)
    context.fill(rect)
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

  /// Debug dump for scroll issues - press Cmd+Shift+D
  private func dumpScrollDebugInfo() {
    var info = "=== SCROLL DEBUG INFO ===\n"
    info += "lines.count: \(lines.count)\n"
    info += "totalContentHeight: \(totalContentHeight)\n"
    info += "frame: \(frame)\n"
    info += "bounds: \(bounds)\n"
    info += "isInLiveResize: \(isInLiveResize)\n"
    info += "isPanelResizing: \(isPanelResizing)\n"

    if let scrollView = enclosingScrollView {
      info += "scrollView.frame: \(scrollView.frame)\n"
      info += "clipView.bounds: \(scrollView.contentView.bounds)\n"
      info += "documentVisibleRect: \(scrollView.documentVisibleRect)\n"
      info += "hasVerticalScroller: \(scrollView.hasVerticalScroller)\n"
      let canScroll = frame.height > scrollView.contentView.bounds.height
      info += "canScroll (contentH > clipH): \(canScroll)\n"
    }

    // Get coordinator state if available
    if let coordinatorInfo = onDebugDump?() {
      info += "\n--- Coordinator State ---\n"
      info += coordinatorInfo
    }

    print(info)

    // Also write to temp file for easy access
    let url = URL(fileURLWithPath: "/tmp/proceed_scroll_debug.log")
    try? info.write(to: url, atomically: true, encoding: .utf8)
    print("Debug info written to /tmp/proceed_scroll_debug.log")
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

    // Debug menu item
    if false {
      menu.addItem(NSMenuItem.separator())
      let debugItem = NSMenuItem(
        title: "Dump Scroll Debug Info", action: #selector(dumpScrollDebugMenuItem(_:)),
        keyEquivalent: "")
      debugItem.target = self
      menu.addItem(debugItem)
    }

    return menu
  }

  @objc func dumpScrollDebugMenuItem(_ sender: Any?) {
    dumpScrollDebugInfo()
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
  let highlightPatterns: [String]
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
    contentView.highlightPatterns = highlightPatterns
    contentView.onClicked = onClicked
    // Don't set lines yet - wait until view is sized
    // Suppress drawing until initial scroll completes
    contentView.suppressDrawing = !lines.isEmpty

    // Handle window resize tailing state - capture coordinator directly
    let coordinator = context.coordinator
    contentView.onResizeStateChanged = { [weak coordinator] isResizing in
      guard let coordinator = coordinator else { return }
      if isResizing {
        // Save and disable tailing
        if coordinator.savedTailingState == nil {
          coordinator.savedTailingState = coordinator.isTailingBinding?.wrappedValue
          if coordinator.savedTailingState == true {
            coordinator.isTailingBinding?.wrappedValue = false
          }
        }
      } else {
        // Restore tailing state
        if let wasTailing = coordinator.savedTailingState {
          coordinator.savedTailingState = nil
          coordinator.isTailingBinding?.wrappedValue = wasTailing
        }
      }
    }

    // Debug dump callback
    contentView.onDebugDump = { [weak coordinator] in
      guard let coordinator = coordinator else { return "coordinator is nil" }
      return coordinator.debugInfo()
    }

    scrollView.documentView = contentView

    // IMPORTANT: Set references BEFORE registering notifications to avoid race condition
    context.coordinator.documentView = contentView
    context.coordinator.scrollView = scrollView
    context.coordinator.isTailingBinding = _isTailing
    context.coordinator.needsInitialScroll = !lines.isEmpty  // Flag for scroll when sized
    context.coordinator.pendingLines = lines.isEmpty ? nil : lines  // Store for deferred population

    // Set up height change callback - re-scroll when tailing and height grows
    // Skip during ANY resize activity to prevent scroll jumping
    contentView.onHeightChanged = { [weak coordinator, weak contentView] in
      guard let coordinator = coordinator,
        let contentView = contentView,
        let scrollView = coordinator.scrollView,
        coordinator.isTailingBinding?.wrappedValue == true
      else { return }

      // Block tailing scroll during any resize activity
      if coordinator.isCurrentlyResizing || contentView.isInLiveResize
        || contentView.isPanelResizing
      {
        return
      }

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
    contentView.highlightPatterns = highlightPatterns

    // Update coordinator's reference to isTailing binding
    context.coordinator.isTailingBinding = _isTailing

    // Skip content updates while waiting for initial scroll - prevents visible scrolling
    if context.coordinator.needsInitialScroll {
      return
    }

    let oldCount = contentView.lines.count
    let newCount = lines.count

    // Detect if this is an initial load (0 -> N lines) and protect from scroll events
    let isInitialLoad = oldCount == 0 && newCount > 0
    if isInitialLoad {
      context.coordinator.isPerformingInitialScroll = true
    }

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
    // Note: setLines and appendLines already call recalculateTotalHeight and needsDisplay
    // Don't redundantly call them here - that was causing excessive CPU usage

    // Scroll to bottom if explicitly requested (user clicked button)
    if scrollToBottom {
      DispatchQueue.main.async {
        self.scrollToBottomIfNeeded(scrollView, measureFirst: true)
        self.scrollToBottom = false
      }
    }
    // On initial load (0 -> N lines), ALWAYS scroll to bottom and enable tailing
    // This ensures panels start at the bottom regardless of any intermediate tailing state changes
    else if isInitialLoad {
      // Defer with delay to ensure view is fully laid out (150ms gives time for layout pass)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
        // Force scroll to bypass resize blocking - initial scroll must always work
        self.scrollToBottomIfNeeded(scrollView, measureFirst: true, forceScroll: true)
        // Ensure tailing is enabled after initial scroll
        if !self.isTailing {
          self.isTailing = true
        }
        // Clear the flag after scroll settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          context.coordinator.isPerformingInitialScroll = false
        }
      }
    }
    // Auto-scroll if tailing is enabled and new lines arrived (not initial load)
    else if newCount != oldCount && isTailing {
      DispatchQueue.main.async {
        self.scrollToBottomIfNeeded(scrollView)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  private func scrollToBottomIfNeeded(
    _ scrollView: NSScrollView, measureFirst: Bool = false, forceScroll: Bool = false,
    retryCount: Int = 0
  ) {
    guard let contentView = scrollView.documentView as? LogContentView else {
      return
    }

    // Block tailing scroll during any resize activity (unless forced for initial scroll)
    if !forceScroll && (contentView.isInLiveResize || contentView.isPanelResizing) {
      return
    }

    // Only measure all heights on explicit request (e.g., initial load)
    // For auto-scroll during tailing, use current frame height (may not be exact but is fast)
    if measureFirst {
      contentView.measureAllHeights()
    }

    let contentHeight = contentView.frame.height
    let maxY = contentHeight - scrollView.contentView.bounds.height

    // If content height is 0 but we have lines, the layout isn't ready yet - retry
    if contentHeight <= 0 && !contentView.lines.isEmpty && retryCount < 3 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
        self.scrollToBottomIfNeeded(
          scrollView, measureFirst: measureFirst, forceScroll: forceScroll,
          retryCount: retryCount + 1)
      }
      return
    }

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
    // Flag to ignore scroll events during initial setup
    var isPerformingInitialScroll: Bool = false

    // Track rapid frame changes to detect programmatic resizing
    private var lastFrameChangeTime: Date?
    private var lastClipHeight: CGFloat = 0  // Track height changes for monitor switching
    private var resizeEndTimer: Timer?
    private var isResizing: Bool = false
    private var resizeEndedAt: Date?  // Track when resize ended for cooldown
    private var savedTopLineIndex: Int?  // Save which line is at top during resize
    var savedTailingState: Bool?  // Save tailing state during resize

    func isAtBottom(_ scrollView: NSScrollView, lineHeight: CGFloat = 16) -> Bool {
      guard let documentView = scrollView.documentView else { return true }
      let visibleHeight = scrollView.contentView.bounds.height
      let contentHeight = documentView.frame.height
      let scrollPosition = scrollView.contentView.bounds.origin.y
      // Consider "at bottom" if within 2 line heights of the bottom
      let threshold = lineHeight * 2
      return scrollPosition >= contentHeight - visibleHeight - threshold
    }

    @objc func scrollViewDidScroll(_ notification: Notification) {
      guard let clipView = notification.object as? NSClipView,
        let scrollView = clipView.enclosingScrollView,
        let contentView = documentView
      else { return }

      // During resize: actively block scroll changes
      if isResizing || contentView.isPanelResizing || contentView.isInLiveResize {
        // If tailing, scroll to bottom; otherwise, scroll to saved line
        if savedTailingState == true {
          // Scroll to bottom during resize to maintain tailing position
          let maxY = contentView.frame.height - clipView.bounds.height
          let currentY = clipView.bounds.origin.y
          if maxY > 0, abs(currentY - maxY) > 1 {
            clipView.scroll(to: NSPoint(x: 0, y: max(0, maxY)))
            scrollView.reflectScrolledClipView(clipView)
          }
        } else if let savedLine = savedTopLineIndex ?? contentView.savedTopLineForWindowResize {
          let estimatedLineHeight = contentView.lineHeight + contentView.lineSpacing
          let targetY = contentView.contentPadding + CGFloat(savedLine) * estimatedLineHeight
          let currentY = clipView.bounds.origin.y
          if abs(currentY - targetY) > 1 {
            clipView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
            scrollView.reflectScrolledClipView(clipView)
          }
        }
        return
      }

      // Don't interpret scroll during cooldown as user action
      if isCurrentlyResizing {
        return
      }

      // Skip tailing updates during initial scroll setup
      if isPerformingInitialScroll {
        return
      }

      let lineHeight = contentView.lineHeight
      let atBottom = isAtBottom(scrollView, lineHeight: lineHeight)
      let currentTailing = isTailingBinding?.wrappedValue ?? false

      // Update tailing state based on scroll position
      if atBottom {
        // Re-enable tailing when user scrolls near the bottom
        if !currentTailing {
          DispatchQueue.main.async { [weak self] in
            self?.isTailingBinding?.wrappedValue = true
          }
        }
      } else {
        // Disable tailing when user scrolls away from bottom
        if currentTailing {
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

      // Perform deferred initial population and scroll once we have a valid size
      if needsInitialScroll && clipView.bounds.height > 0 && clipView.bounds.width > 0 {
        needsInitialScroll = false
        isPerformingInitialScroll = true  // Prevent scroll events from disabling tailing

        // Now populate with lines (view is sized, so heights can be calculated properly)
        if let lines = pendingLines {
          pendingLines = nil
          contentView.frame.size.width = clipView.bounds.width
          contentView.setLines(lines)
          // Force measurement of all lines to ensure accurate height for scrolling
          // This prevents visual jumping/scrolling artifacts on initial load
          contentView.measureAllHeights()
        }

        // Now allow drawing
        contentView.suppressDrawing = false
        contentView.needsDisplay = true

        // Defer scroll with small delay to ensure layout is fully complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          [weak self, weak scrollView, weak contentView] in
          guard let self = self, let scrollView = scrollView, let contentView = contentView else {
            return
          }
          // Re-measure to ensure frame is accurate after layout
          contentView.measureAllHeights()
          let maxY = contentView.frame.height - scrollView.contentView.bounds.height
          scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, maxY)))
          scrollView.reflectScrolledClipView(scrollView.contentView)

          // Clear the flag after scroll settles
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isPerformingInitialScroll = false
          }
        }
        return
      }

      // Skip resize detection during initial scroll setup
      if isPerformingInitialScroll {
        return
      }

      // Track rapid frame changes to detect resize operations
      let now = Date()
      let isRapidChange = lastFrameChangeTime.map { now.timeIntervalSince($0) < 0.15 } ?? false
      lastFrameChangeTime = now

      // Cancel any pending resize-end timer
      resizeEndTimer?.invalidate()

      let newWidth = clipView.bounds.width
      let newHeight = clipView.bounds.height
      let widthChanged = newWidth > 0 && abs(contentView.bounds.width - newWidth) > 0.5
      let heightChanged = newHeight > 0 && abs(lastClipHeight - newHeight) > 0.5
      lastClipHeight = newHeight
      let sizeChanged = widthChanged || heightChanged

      if sizeChanged {
        // During resize: handle tailing state preservation
        // Trigger on rapid changes, window live resize, OR if we're tailing (for monitor switches)
        let currentTailing = isTailingBinding?.wrappedValue ?? false
        let shouldHandleResize =
          isRapidChange || contentView.isInLiveResize || currentTailing
        if shouldHandleResize {
          // Save state on first resize frame (only if not already saved by onResizeStateChanged)
          if !isResizing {
            savedTopLineIndex = contentView.topVisibleLineIndex()
            // Only save tailing state if not already saved (avoids race with onResizeStateChanged)
            if savedTailingState == nil {
              savedTailingState = isTailingBinding?.wrappedValue
              if savedTailingState == true {
                isTailingBinding?.wrappedValue = false
              }
            }
          }
          isResizing = true
          contentView.isPanelResizing = true  // Tell content view to skip expensive drawing
          contentView.frame.size.width = newWidth
          // Don't set needsDisplay - wait until resize ends to redraw

          // Schedule resize-end handler
          resizeEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) {
            [weak self] _ in
            guard let self = self, let contentView = self.documentView else { return }
            self.isResizing = false
            self.resizeEndedAt = Date()  // Record for cooldown period
            contentView.isPanelResizing = false
            contentView.handleResizeEnded()

            // Restore scroll position based on whether we were tailing
            if let wasTailing = self.savedTailingState {
              self.savedTailingState = nil
              if wasTailing {
                // Was tailing - scroll to bottom and restore tailing state
                // Must defer to next run loop - scroll view isn't ready immediately after handleResizeEnded()
                DispatchQueue.main.async { [weak self, weak contentView] in
                  guard let self = self, let contentView = contentView,
                    let scrollView = self.scrollView
                  else { return }
                  let maxY = contentView.frame.height - scrollView.contentView.bounds.height
                  scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, maxY)))
                  scrollView.reflectScrolledClipView(scrollView.contentView)
                  self.isTailingBinding?.wrappedValue = true
                }
              }
              // If was NOT tailing, don't restore position - let it stay where it ended up
              // The savedTopLineIndex becomes stale during vigorous resize
              self.savedTopLineIndex = nil
            } else {
              // No tailing state saved - don't try to restore position
              self.savedTopLineIndex = nil
            }
          }
        } else {
          // Single frame change (not rapid resize) - update width and redraw
          contentView.frame.size.width = newWidth
          contentView.needsDisplay = true
        }
      }
    }

    /// Whether we're currently in a resize operation (includes cooldown period)
    var isCurrentlyResizing: Bool {
      if isResizing || (documentView?.isInLiveResize ?? false) {
        return true
      }
      // 1 second cooldown after resize ends to let heights settle and tailing restore
      if let endedAt = resizeEndedAt, Date().timeIntervalSince(endedAt) < 1.0 {
        return true
      }
      return false
    }

    /// Debug info for scroll issues
    func debugInfo() -> String {
      var info = ""
      info += "isPerformingInitialScroll: \(isPerformingInitialScroll)\n"
      info += "needsInitialScroll: \(needsInitialScroll)\n"
      info += "isResizing: \(isResizing)\n"
      info += "isCurrentlyResizing: \(isCurrentlyResizing)\n"
      info += "isTailing: \(isTailingBinding?.wrappedValue ?? false)\n"
      info += "savedTailingState: \(String(describing: savedTailingState))\n"
      info += "resizeEndedAt: \(String(describing: resizeEndedAt))\n"
      info += "lastFrameChangeTime: \(String(describing: lastFrameChangeTime))\n"
      info += "pendingLines count: \(pendingLines?.count ?? -1)\n"
      return info
    }
  }
}
