import SwiftUI

// MARK: - Focused Values for Menu Commands

struct FocusedTilingStateKey: FocusedValueKey {
  typealias Value = TilingState
}

extension FocusedValues {
  var tilingState: TilingState? {
    get { self[FocusedTilingStateKey.self] }
    set { self[FocusedTilingStateKey.self] = newValue }
  }
}

// MARK: - App

@main
struct ProceedApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @ObservedObject private var settingsManager = SettingsManager.shared
  @FocusedValue(\.tilingState) var focusedTilingState

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(settingsManager)
        .preferredColorScheme(settingsManager.colorScheme)
    }
    .windowStyle(.automatic)
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Window") {
          NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("n", modifiers: .command)
      }

      // Add items to the existing View menu
      CommandGroup(after: .toolbar) {
        Divider()

        Button("Run Process…") {
          focusedTilingState?.editingPanelId = nil
          focusedTilingState?.showRunDialog = true
        }
        .keyboardShortcut("r", modifiers: .command)

        Button("Filter") {
          focusedTilingState?.showFilterBarTrigger += 1
        }
        .keyboardShortcut("f", modifiers: .command)

        Divider()

        Button("Edit Panel…") {
          if let panelId = focusedTilingState?.focusedPanelId {
            focusedTilingState?.editingPanelId = panelId
            focusedTilingState?.showRunDialog = true
          }
        }
        .keyboardShortcut("e", modifiers: .command)

        Button("Start/Stop") {
          if let panelId = focusedTilingState?.focusedPanelId {
            focusedTilingState?.toggleProcess(forPanelId: panelId)
          }
        }
        .keyboardShortcut("s", modifiers: .command)

        Button("Restart") {
          if let panelId = focusedTilingState?.focusedPanelId {
            focusedTilingState?.reloadProcess(forPanelId: panelId)
          }
        }
        .keyboardShortcut("p", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(settingsManager)
    }

  }
}

// MARK: - App Delegate with Menu Bar Support

class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var settingsObserver: NSObjectProtocol?
  private var httpAPIObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Set up menu bar status item if enabled
    updateStatusItemVisibility()

    // Observe settings changes for menu bar toggle
    settingsObserver = NotificationCenter.default.addObserver(
      forName: .menuBarExtraChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateStatusItemVisibility()
    }

    // Start HTTP API server if enabled
    updateHTTPServerState()

    // Observe settings changes for HTTP API toggle
    httpAPIObserver = NotificationCenter.default.addObserver(
      forName: .httpAPIEnabledChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateHTTPServerState()
    }

    // Create additional windows for any remaining saved states
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.restoreAdditionalWindows()
    }
  }

  private func updateHTTPServerState() {
    let enabled = SettingsManager.shared.httpAPIEnabled
    print("AppDelegate: updateHTTPServerState() - httpAPIEnabled=\(enabled)")
    if enabled {
      HTTPServer.shared.start()
    } else {
      HTTPServer.shared.stop()
    }
  }

  private func updateStatusItemVisibility() {
    let shouldShow = SettingsManager.shared.showMenuBarExtra

    if shouldShow && statusItem == nil {
      createStatusItem()
    } else if !shouldShow && statusItem != nil {
      NSStatusBar.system.removeStatusItem(statusItem!)
      statusItem = nil
    }
  }

  private func createStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusItem?.button {
      button.image = createTerminalIcon()
    }

    updateStatusItemMenu()
  }

  private func createTerminalIcon() -> NSImage {
    let size = NSSize(width: 18, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
      // Draw rounded rectangle outline (terminal window)
      let borderRect = rect.insetBy(dx: 1, dy: 1)
      let path = NSBezierPath(roundedRect: borderRect, xRadius: 2, yRadius: 2)
      path.lineWidth = 1.2
      NSColor.black.setStroke()
      path.stroke()

      // Draw horizontal lines inside (terminal text)
      let lineSpacing: CGFloat = 3.5
      let lineInset: CGFloat = 4.0
      let startY: CGFloat = 4.5

      for i in 0..<3 {
        let y = startY + CGFloat(i) * lineSpacing
        let lineWidth: CGFloat = i == 2 ? 6 : 10  // Shorter last line
        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: lineInset, y: y))
        linePath.line(to: NSPoint(x: lineInset + lineWidth, y: y))
        linePath.lineWidth = 1.2
        linePath.stroke()
      }

      return true
    }
    image.isTemplate = true
    return image
  }

  private func updateStatusItemMenu() {
    let menu = NSMenu()

    // Get panel snapshots
    let panels = WindowManager.shared.allPanelSnapshots()

    if panels.isEmpty {
      let item = NSMenuItem(title: "No panels", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    } else {
      // Group panels by window
      var panelsByWindow: [UUID: [WindowManager.PanelSnapshot]] = [:]
      for panel in panels {
        panelsByWindow[panel.windowId, default: []].append(panel)
      }

      // Sort windows by their first panel's title for consistent ordering
      let sortedWindows = panelsByWindow.keys.sorted { windowId1, windowId2 in
        let title1 = panelsByWindow[windowId1]?.first?.title ?? ""
        let title2 = panelsByWindow[windowId2]?.first?.title ?? ""
        return title1 < title2
      }

      var isFirstWindow = true
      for windowId in sortedWindows {
        guard let windowPanels = panelsByWindow[windowId] else { continue }

        // Add separator between windows
        if !isFirstWindow {
          menu.addItem(NSMenuItem.separator())
        }
        isFirstWindow = false

        // Sort panels within window by title
        let sortedPanels = windowPanels.sorted { $0.title < $1.title }

        for panel in sortedPanels {
          let item = NSMenuItem(
            title: panel.title,
            action: #selector(panelMenuItemClicked(_:)),
            keyEquivalent: ""
          )
          item.target = self
          item.representedObject = ["windowId": panel.windowId, "panelId": panel.panelId]

          // Set status indicator with appropriate color
          item.image = createStatusDot(running: panel.isRunning)

          menu.addItem(item)
        }
      }
    }

    menu.addItem(NSMenuItem.separator())

    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)

    let quitItem = NSMenuItem(title: "Quit Proceed", action: #selector(quitApp), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    // Set delegate to refresh menu when opened
    menu.delegate = self
    statusItem?.menu = menu
  }

  private func createStatusDot(running: Bool) -> NSImage {
    let size = NSSize(width: 10, height: 10)
    let image = NSImage(size: size, flipped: false) { rect in
      let dotRect = rect.insetBy(dx: 2, dy: 2)
      let path = NSBezierPath(ovalIn: dotRect)

      if running {
        // Solid green dot for running (#007F08)
        NSColor(red: 0.0, green: 0.498, blue: 0.031, alpha: 1.0).setFill()
        path.fill()
      } else {
        // Dark gray outline for stopped
        NSColor(white: 0.4, alpha: 1.0).setStroke()
        path.lineWidth = 1.2
        path.stroke()
      }

      return true
    }
    return image
  }

  @objc private func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    // Simulate Cmd+, keyboard shortcut to open Settings
    // This works reliably with SwiftUI's Settings scene
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: ",",
      charactersIgnoringModifiers: ",",
      isARepeat: false,
      keyCode: 43  // Comma key
    )
    if let event = event {
      NSApp.sendEvent(event)
    }
  }

  @objc private func panelMenuItemClicked(_ sender: NSMenuItem) {
    guard let info = sender.representedObject as? [String: UUID],
          let windowId = info["windowId"],
          let panelId = info["panelId"] else { return }

    WindowManager.shared.activateWindowAndFocusPanel(windowId: windowId, panelId: panelId)
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  private func restoreAdditionalWindows() {
    // Create windows for any remaining saved states
    let remainingCount = WindowManager.shared.pendingStateCount()
    guard remainingCount > 0 else {
      WindowManager.shared.endRestoration()
      return
    }

    for _ in 0..<remainingCount {
      NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
    }

    // End restoration after windows are created
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      WindowManager.shared.endRestoration()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Stop HTTP server
    HTTPServer.shared.stop()

    // Save state before windows close
    WindowManager.shared.beginTermination()
    WindowManager.shared.saveAllStates()
    return .terminateNow
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

// MARK: - NSMenuDelegate for Menu Bar

extension AppDelegate: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    // Refresh menu content when opened
    updateStatusItemMenu()
  }
}
