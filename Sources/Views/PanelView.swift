import SwiftUI

struct PanelView: View {
  @ObservedObject var panel: Panel
  @EnvironmentObject var tilingState: TilingState
  @EnvironmentObject var settingsManager: SettingsManager
  @Environment(\.colorScheme) private var colorScheme

  // Tailing state
  @State private var isTailing: Bool = true

  // Duration timer
  @State private var currentTime: Date = Date()
  private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  // Filter bar state
  @State private var isFilterBarVisible: Bool = false
  @State private var filterText: String = ""
  @State private var debouncedFilterText: String = ""
  @FocusState private var isFilterFieldFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      if !panel.isMinimized {
        if isFilterBarVisible {
          filterBar
        }
        contentArea
      }
    }
    .background(Color(NSColor.windowBackgroundColor))
    .cornerRadius(6)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      // Clicking anywhere in panel focuses it
      tilingState.focusedPanelId = panel.id
    }
    .opacity(isDraggingThisPanel ? 0.5 : 1.0)
    .onReceive(durationTimer) { time in
      // Only update if running (stopped processes don't need updates)
      if isRunning {
        currentTime = time
      }
    }
    .onReceive(panel.objectWillChange) { _ in
      // Explicit subscription to panel changes - ensures view updates
      // even when @ObservedObject subscription is lost (e.g., for restored panels)
    }
    .onChange(of: tilingState.showFilterBarTrigger) { _ in
      // Show filter bar when triggered and this panel is focused
      if isFocused && !isFilterBarVisible {
        isFilterBarVisible = true
        isFilterFieldFocused = true
      }
    }
    .onChange(of: panel.isLoadingHistory) { isLoading in
      // When history finishes loading, scroll to bottom if tailing
      if !isLoading && isTailing {
        // Small delay to let the view update with new lines
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          scrollToBottomTrigger = true
        }
      }
    }
  }

  // MARK: - Filtered Lines

  /// Lines filtered by the current search regex and exclusion filters
  private var filteredLines: [OutputLine] {
    var lines = panel.lines

    // Apply search filter if present
    let pattern = debouncedFilterText.trimmingCharacters(in: .whitespaces)
    if !pattern.isEmpty && pattern != ".*" {
      if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        lines = lines.filter { line in
          let text = line.rawText
          let range = NSRange(text.startIndex..., in: text)
          return regex.firstMatch(in: text, options: [], range: range) != nil
        }
      }
    }

    // Apply per-process exclusion filters
    if let excludePatterns = panel.processConfig?.outputExcludeFilters, !excludePatterns.isEmpty {
      let excludeRegexes = excludePatterns.compactMap { pattern in
        try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
      }
      if !excludeRegexes.isEmpty {
        lines = lines.filter { line in
          let text = line.rawText
          let range = NSRange(text.startIndex..., in: text)
          // Keep line only if NO exclusion pattern matches
          return !excludeRegexes.contains { regex in
            regex.firstMatch(in: text, options: [], range: range) != nil
          }
        }
      }
    }

    return lines
  }

  private var isDraggingThisPanel: Bool {
    tilingState.dragState?.draggedPanelId == panel.id
  }

  private var isRunning: Bool {
    panel.status == .running
  }

  private var isFocused: Bool {
    tilingState.focusedPanelId == panel.id
  }

  private var titleBarBackground: Color {
    if isDraggingThisPanel {
      return Color.blue.opacity(0.3)
    } else if isFocused {
      // Subtle highlight for focused panel
      // Light mode: #fcfcfc, Dark mode: #444444
      return colorScheme == .dark
        ? Color(red: 0x44 / 255.0, green: 0x44 / 255.0, blue: 0x44 / 255.0)
        : Color(red: 0xfc / 255.0, green: 0xfc / 255.0, blue: 0xfc / 255.0)
    } else {
      return Color(NSColor.controlBackgroundColor)
    }
  }

  /// Formatted duration string (e.g., "1h32m5s", "32m5s", "5s")
  private var formattedDuration: String? {
    if case .restarting(let target) = panel.status {
      let remaining = target.timeIntervalSince(currentTime)
      if remaining > 0 {
        return "Restarting in \(Int(ceil(remaining)))s"
      } else {
        return "Restarting..."
      }
    }
  
    guard let startedAt = panel.startedAt else { return nil }

    let endTime = panel.stoppedAt ?? currentTime
    let duration = endTime.timeIntervalSince(startedAt)

    guard duration >= 0 else { return nil }

    let hours = Int(duration) / 3600
    let minutes = (Int(duration) % 3600) / 60
    let seconds = Int(duration) % 60

    if hours > 0 {
      return "\(hours)h\(minutes)m\(seconds)s"
    } else if minutes > 0 {
      return "\(minutes)m\(seconds)s"
    } else {
      return "\(seconds)s"
    }
  }

  @State private var isReloading: Bool = false
  @State private var scrollToBottomTrigger: Bool = false

  private var titleBar: some View {
    HStack(spacing: 8) {
      TitleBarButton(
        icon: "xmark",
        color: .secondary,
        help: "Close panel"
      ) {
        tilingState.closePanel(id: panel.id)
      }

      // Minimize button (only show if more than one panel)
      if tilingState.canMinimize(panelId: panel.id) {
        TitleBarButton(
          icon: panel.isMinimized ? "chevron.down" : "chevron.up",
          color: .secondary,
          help: panel.isMinimized ? "Expand panel" : "Minimize panel"
        ) {
          withAnimation(.easeInOut(duration: 0.2)) {
            tilingState.toggleMinimize(panelId: panel.id)
          }
        }
      }

      Circle()
        .fill(panel.status.color)
        .frame(width: 8, height: 8)

      Text(panel.title)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.primary)

      Spacer()

      // Duration display
      if let durationText = formattedDuration {
        Text(durationText)
          .font(.system(size: 10, weight: .regular, design: .monospaced))
          .foregroundColor(.secondary.opacity(0.6))
          .padding(.trailing, 4)
      }

      // Right-aligned action buttons
      HStack(spacing: 6) {
        // Auto-reload indicator
        if panel.processConfig?.autoReloadEnabled == true {
          Text("Auto Reload")
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.2))
            .foregroundColor(.green)
            .cornerRadius(4)
            .help("Auto reload is enabled")
        }

        // Tail indicator - shows autoscroll state, click to jump to bottom
        TitleBarButton(
          icon: "arrow.down.to.line",
          color: isTailing ? .green : .secondary,
          help: isTailing ? "Following output" : "Click to follow output"
        ) {
          scrollToBottomTrigger = true
          isTailing = true
        }

        TitleBarButton(
          icon: "pencil",
          color: .secondary,
          help: "Edit process"
        ) {
          tilingState.editingPanelId = panel.id
          tilingState.showRunDialog = true
        }

        TitleBarButton(
          icon: "arrow.clockwise",
          color: .blue,
          help: "Reload (stop and start)",
          disabled: isReloading || !isRunning
        ) {
          reloadProcess()
        }

        TitleBarButton(
          icon: isRunning ? "stop.fill" : "play.fill",
          color: isRunning ? .orange : .green,
          help: isRunning ? "Stop process" : "Start process"
        ) {
          if isRunning {
            tilingState.stopProcess(forPanelId: panel.id)
          } else {
            tilingState.restartProcess(forPanelId: panel.id)
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(titleBarBackground)
    .contentShape(Rectangle())
    .onTapGesture {
      tilingState.focusedPanelId = panel.id
    }
    .onDrag {
      tilingState.startDrag(panelId: panel.id, location: .zero)
      var monitor: Any?
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
        if tilingState.dragState?.draggedPanelId == panel.id {
          tilingState.cancelDrag()
        }
        if let monitor = monitor {
          NSEvent.removeMonitor(monitor)
        }
        return event
      }
      return NSItemProvider(object: panel.id.uuidString as NSString)
    }
  }

  private func reloadProcess() {
    guard isRunning, !isReloading else { return }
    isReloading = true

    // Stop the process
    tilingState.stopProcess(forPanelId: panel.id)

    // Watch for the process to stop, then restart
    Task {
      // Wait for process to stop (poll every 100ms, max 10 seconds)
      for _ in 0..<100 {
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        if panel.status != .running {
          break
        }
      }

      // Restart the process
      await MainActor.run {
        tilingState.restartProcess(forPanelId: panel.id)
        isReloading = false
      }
    }
  }

  private var contentArea: some View {
    ZStack {
      LogContentViewRepresentable(
        lines: filteredLines,
        font: NSFont.monospacedSystemFont(ofSize: settingsManager.fontSize, weight: .regular),
        gutterWidth: 85,
        highlightPatterns: panel.processConfig?.highlightPatterns ?? [],
        onClicked: {
          tilingState.focusedPanelId = panel.id
        },
        scrollToBottom: $scrollToBottomTrigger,
        isTailing: $isTailing
      )

      if panel.isLoadingHistory {
        ProgressView()
          .scaleEffect(0.8)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(NSColor.textBackgroundColor).opacity(0.3))
      }
    }
    .allowsHitTesting(!isDraggingThisPanel)
    .onAppear {
      isTailing = true
    }
    .background {
      Button("") { settingsManager.fontSize += 1 }.keyboardShortcut("+", modifiers: .command)
        .opacity(0)
      Button("") { settingsManager.fontSize = max(6, settingsManager.fontSize - 1) }
        .keyboardShortcut("-", modifiers: .command).opacity(0)
    }
  }

  // MARK: - Filter Bar

  private var filterBar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        FunnelIcon()
          .foregroundColor(.secondary)
          .frame(width: 12, height: 12)

        FilterTextField(text: $filterText, fontSize: settingsManager.fontSize)
          .focused($isFilterFieldFocused)
          .onChange(of: filterText) { newValue in
            debounceFilterUpdate(newValue)
          }

        if !filterText.isEmpty {
          Text("\(filteredLines.count)/\(panel.lines.count)")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }

        Button(action: closeFilterBar) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help("Close filter (Esc)")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color(NSColor.controlBackgroundColor))

      Divider()
    }
    .onExitCommand {
      closeFilterBar()
    }
  }

  private func closeFilterBar() {
    isFilterBarVisible = false
    filterText = ""
    debouncedFilterText = ""
    isFilterFieldFocused = false
  }

  @State private var filterDebounceTask: Task<Void, Never>?

  private func debounceFilterUpdate(_ newValue: String) {
    filterDebounceTask?.cancel()
    filterDebounceTask = Task {
      try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms debounce
      if !Task.isCancelled {
        await MainActor.run {
          debouncedFilterText = newValue
        }
      }
    }
  }
}

// MARK: - Subviews

/// Classic funnel/filter icon shape
struct FunnelIcon: View {
  var body: some View {
    GeometryReader { geo in
      Path { path in
        let w = geo.size.width
        let h = geo.size.height
        let stemWidth = w * 0.25
        let stemHeight = h * 0.35
        let funnelTop = h * 0.15

        // Start at top-left
        path.move(to: CGPoint(x: 0, y: funnelTop))
        // Top edge
        path.addLine(to: CGPoint(x: w, y: funnelTop))
        // Right side down to stem
        path.addLine(to: CGPoint(x: (w + stemWidth) / 2, y: h - stemHeight))
        // Right side of stem
        path.addLine(to: CGPoint(x: (w + stemWidth) / 2, y: h))
        // Bottom of stem
        path.addLine(to: CGPoint(x: (w - stemWidth) / 2, y: h))
        // Left side of stem
        path.addLine(to: CGPoint(x: (w - stemWidth) / 2, y: h - stemHeight))
        // Left side up to top
        path.addLine(to: CGPoint(x: 0, y: funnelTop))
        path.closeSubpath()
      }
      .fill()
    }
  }
}

/// Single-line text field that ignores Return/Option+Return
struct FilterTextField: NSViewRepresentable {
  @Binding var text: String
  let fontSize: CGFloat

  func makeNSView(context: Context) -> NSTextField {
    let textField = NSTextField()
    textField.stringValue = text
    textField.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    textField.isBordered = false
    textField.backgroundColor = .clear
    textField.focusRingType = .none
    textField.placeholderString = "Filter (regex)"
    textField.delegate = context.coordinator
    return textField
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: FilterTextField

    init(_ parent: FilterTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let textField = obj.object as? NSTextField else { return }
      parent.text = textField.stringValue
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      // Intercept Return and Option+Return (insertNewline and insertNewlineIgnoringFieldEditor)
      if commandSelector == #selector(NSResponder.insertNewline(_:))
        || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
      {
        return true  // Consume the event
      }
      return false
    }
  }
}

struct TitleBarButton: View {
  let icon: String
  let color: Color
  let help: String
  var disabled: Bool = false
  let action: () -> Void

  @State private var isHovered: Bool = false
  @State private var isPressed: Bool = false

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(disabled ? .secondary.opacity(0.4) : color)
        .frame(width: 18, height: 18)
        .background(backgroundColor)
        .clipShape(Circle())
        .scaleEffect(isPressed ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(help)
    .onHover { hovering in
      isHovered = hovering
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in isPressed = true }
        .onEnded { _ in isPressed = false }
    )
  }

  private var backgroundColor: Color {
    if disabled {
      return Color.gray.opacity(0.1)
    }
    if isPressed {
      return color.opacity(0.3)
    }
    if isHovered {
      return color.opacity(0.2)
    }
    return Color.gray.opacity(0.15)
  }
}
