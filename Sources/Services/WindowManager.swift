import Foundation
import SwiftUI

/// Manages multiple window states for persistence
class WindowManager: ObservableObject {
  static let shared = WindowManager()

  /// All active tiling states, keyed by window ID
  private var windowStates: [UUID: TilingState] = [:]
  /// Associated NSWindows for frame tracking
  private var nsWindows: [UUID: NSWindow] = [:]
  private let lock = NSLock()

  /// Saved states waiting to be claimed by windows on restore
  private var pendingRestoreStates: [WindowStateData] = []
  private var hasLoadedPendingStates = false
  /// Whether we're still in the restoration window
  private var isRestorationActive = true
  /// Whether the app is terminating
  private var isTerminating = false

  private init() {}

  /// Register a window's tiling state
  func register(windowId: UUID, state: TilingState, window: NSWindow? = nil) {
    lock.lock()
    windowStates[windowId] = state
    if let window = window {
      nsWindows[windowId] = window
    }
    lock.unlock()
  }

  /// Associate an NSWindow with a window ID (called when window becomes available)
  func associateWindow(_ window: NSWindow, with windowId: UUID) {
    lock.lock()
    nsWindows[windowId] = window
    lock.unlock()
  }

  /// Unregister a window when it closes
  func unregister(windowId: UUID) {
    lock.lock()
    if isTerminating {
      lock.unlock()
      return
    }
    windowStates.removeValue(forKey: windowId)
    nsWindows.removeValue(forKey: windowId)
    lock.unlock()
  }

  /// Save all window states
  func saveAllStates() {
    lock.lock()
    let states = windowStates
    lock.unlock()

    var allWindowStates: [WindowStateData] = []

    for (windowId, tilingState) in states {
      guard !tilingState.panels.isEmpty else { continue }

      var panelStates: [PanelState] = []
      for (_, panel) in tilingState.panels {
        let configState: ProcessConfigState? = panel.processConfig.map {
          ProcessConfigState(
            name: $0.name,
            command: $0.command,
            workingDirectory: $0.workingDirectory,
            shell: $0.shell
          )
        }

        let statusState: PanelStatusState
        switch panel.status {
        case .running:
          statusState = .running
        case .exitedNormally:
          statusState = .exitedNormally
        case .exitedWithError(let code):
          statusState = .exitedWithError(code: code)
        }

        let handleId = panel.tmuxHandleId

        panelStates.append(
          PanelState(
            id: panel.id,
            title: panel.title,
            processConfig: configState,
            status: statusState,
            handleId: handleId
          ))
      }

      let layoutNode = tilingState.rootNode.map { convertToLayoutNode($0) }

      // Get window frame
      let frame = nsWindows[windowId]?.frame

      allWindowStates.append(
        WindowStateData(
          windowId: windowId,
          panels: panelStates,
          layout: layoutNode,
          lastWorkingDirectory: tilingState.lastWorkingDirectory,
          lastCommand: tilingState.lastCommand,
          frameX: frame?.origin.x,
          frameY: frame?.origin.y,
          frameWidth: frame?.size.width,
          frameHeight: frame?.size.height
        ))
    }

    let multiWindowState = MultiWindowState(windows: allWindowStates)
    PersistenceManager.shared.saveMultiWindowState(multiWindowState)
  }

  /// Claim the next available saved state for a new window
  func claimNextState() -> WindowStateData? {
    lock.lock()
    defer { lock.unlock() }

    guard isRestorationActive else { return nil }

    if !hasLoadedPendingStates {
      pendingRestoreStates = PersistenceManager.shared.loadMultiWindowState()?.windows ?? []
      hasLoadedPendingStates = true
    }

    if let index = pendingRestoreStates.firstIndex(where: { !$0.panels.isEmpty }) {
      return pendingRestoreStates.remove(at: index)
    }

    return nil
  }

  /// End the restoration window
  func endRestoration() {
    lock.lock()
    isRestorationActive = false
    pendingRestoreStates.removeAll()
    lock.unlock()
  }

  /// Get count of pending states
  func pendingStateCount() -> Int {
    lock.lock()
    defer { lock.unlock() }

    if !hasLoadedPendingStates {
      pendingRestoreStates = PersistenceManager.shared.loadMultiWindowState()?.windows ?? []
      hasLoadedPendingStates = true
    }

    return pendingRestoreStates.filter { !$0.panels.isEmpty }.count
  }

  /// Mark that the app is terminating
  func beginTermination() {
    lock.lock()
    isTerminating = true
    lock.unlock()
  }

  // MARK: - Cross-Window Panel Transfer

  /// Find a panel by ID across all windows, returning the source TilingState if found
  func findPanel(id panelId: UUID) -> (panel: Panel, process: RunningProcess?, source: TilingState)?
  {
    lock.lock()
    let states = windowStates
    lock.unlock()

    for (_, tilingState) in states {
      if let panel = tilingState.panels[panelId] {
        let process = tilingState.processes.values.first { $0.panelId == panelId }
        return (panel, process, tilingState)
      }
    }
    return nil
  }

  /// Transfer a panel from source to target TilingState
  /// Returns true if transfer was successful
  func transferPanel(panelId: UUID, to target: TilingState) -> Bool {
    lock.lock()
    let states = windowStates
    lock.unlock()

    // Find source TilingState
    var sourceState: TilingState?
    var panel: Panel?
    var runningProcess: RunningProcess?

    for (_, tilingState) in states {
      if tilingState === target { continue }
      if let p = tilingState.panels[panelId] {
        sourceState = tilingState
        panel = p
        runningProcess = tilingState.processes.values.first { $0.panelId == panelId }
        break
      }
    }

    guard let source = sourceState, let panelToTransfer = panel else {
      return false
    }

    // Transfer panel
    target.panels[panelId] = panelToTransfer

    // Transfer running process if any
    if let process = runningProcess {
      let processId = process.config.id
      source.processes.removeValue(forKey: processId)
      target.processes[processId] = process
    }

    // Remove panel from source layout
    source.panels.removeValue(forKey: panelId)
    if let root = source.rootNode {
      source.rootNode = root.removing(panelId: panelId)
    }

    return true
  }

  private func convertToLayoutNode(_ node: TileNode) -> LayoutNode {
    switch node {
    case .leaf(let id, let panelId):
      return .leaf(id: id, panelId: panelId)
    case .split(let id, let direction, let first, let second, let ratio):
      let layoutDir: LayoutDirection = direction == .horizontal ? .horizontal : .vertical
      return .split(
        id: id,
        direction: layoutDir,
        first: convertToLayoutNode(first.value),
        second: convertToLayoutNode(second.value),
        ratio: ratio
      )
    }
  }
}

/// State data for a single window
struct WindowStateData: Codable {
  let windowId: UUID
  let panels: [PanelState]
  let layout: LayoutNode?
  let lastWorkingDirectory: String
  let lastCommand: String?
  let frameX: CGFloat?
  let frameY: CGFloat?
  let frameWidth: CGFloat?
  let frameHeight: CGFloat?
}

/// State for all windows
struct MultiWindowState: Codable {
  let windows: [WindowStateData]
}
