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

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Create additional windows for any remaining saved states
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.restoreAdditionalWindows()
    }
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
    // Save state before windows close
    WindowManager.shared.beginTermination()
    WindowManager.shared.saveAllStates()
    return .terminateNow
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}
