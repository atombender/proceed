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

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      contentArea
    }
    .background(Color(NSColor.windowBackgroundColor))
    .cornerRadius(6)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    )
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
    LogContentViewRepresentable(
      lines: panel.lines,
      font: NSFont.monospacedSystemFont(ofSize: settingsManager.fontSize, weight: .regular),
      gutterWidth: 85,
      scrollToBottom: $scrollToBottomTrigger,
      isTailing: $isTailing
    )
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
}

// MARK: - Subviews

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
