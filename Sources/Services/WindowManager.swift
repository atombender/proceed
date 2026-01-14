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

  /// Debounce timer for auto-save
  private var saveDebounceWorkItem: DispatchWorkItem?
  private let saveQueue = DispatchQueue(label: "com.proceed.windowmanager.save", qos: .utility)

  private init() {}

  /// Schedule a debounced save (coalesces rapid changes)
  func scheduleSave() {
    lock.lock()
    // Cancel any pending save
    saveDebounceWorkItem?.cancel()

    // Capture window frames on main thread (UI API)
    let windowFrames = captureWindowFrames()

    // Schedule new save after 1 second of inactivity
    let workItem = DispatchWorkItem { [weak self] in
      self?.saveAllStates(windowFrames: windowFrames)
    }
    saveDebounceWorkItem = workItem
    lock.unlock()

    saveQueue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  /// Save immediately, bypassing debounce (for critical operations like panel creation)
  func saveNow() {
    lock.lock()
    // Cancel any pending debounced save
    saveDebounceWorkItem?.cancel()
    saveDebounceWorkItem = nil

    // Capture window frames on main thread
    let windowFrames = captureWindowFrames()
    lock.unlock()

    // Execute save synchronously on the save queue
    saveQueue.sync {
      self.saveAllStates(windowFrames: windowFrames)
    }
  }

  /// Capture window frames - must be called on main thread
  private func captureWindowFrames() -> [UUID: NSRect] {
    var frames: [UUID: NSRect] = [:]
    for (windowId, window) in nsWindows {
      frames[windowId] = window.frame
    }
    return frames
  }

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

    // Also delete from SQLite storage
    PersistenceManager.shared.deleteWindow(windowId)
  }

  /// Save all window states
  /// - Parameter windowFrames: Pre-captured window frames (captured on main thread)
  func saveAllStates(windowFrames: [UUID: NSRect]? = nil) {
    lock.lock()
    let states = windowStates
    // If no frames provided, capture them now (assumes we're on main thread)
    let frames = windowFrames ?? captureWindowFrames()
    lock.unlock()

    var allWindowStates: [WindowStateData] = []

    // Sort by windowId for deterministic save order (matches restore order)
    let sortedStates = states.sorted { $0.key.uuidString < $1.key.uuidString }

    for (windowId, tilingState) in sortedStates {
      guard !tilingState.panels.isEmpty else { continue }

      var panelStates: [PanelState] = []
      for (_, panel) in tilingState.panels {
        let configState: ProcessConfigState? = panel.processConfig.map {
          ProcessConfigState(
            id: $0.id,  // Preserve config ID for tmux session reconnection
            name: $0.name,
            command: $0.command,
            workingDirectory: $0.workingDirectory,
            shell: $0.shell,
            autoReloadEnabled: $0.autoReloadEnabled,
            autoReloadIncludes: $0.autoReloadIncludes,
            autoReloadExcludes: $0.autoReloadExcludes,
            autoRestart: $0.autoRestart,
            outputExcludeFilters: $0.outputExcludeFilters,
            highlightPatterns: $0.highlightPatterns
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
        case .restarting:
          // Treat restarting as exited for persistence (transient state)
          statusState = .exitedNormally
        }

        // Compute handleId from config.id to ensure they're always in sync
        // The tmux session name is always "proceed-{config.id}"
        let handleId: String? = panel.processConfig.map { "proceed-\($0.id.uuidString)" }

        panelStates.append(
          PanelState(
            id: panel.id,
            title: panel.title,
            processConfig: configState,
            status: statusState,
            handleId: handleId,
            isMinimized: panel.isMinimized,
            rememberedRatio: panel.rememberedRatio
          ))
      }

      let layoutNode = tilingState.rootNode.map { convertToLayoutNode($0) }

      // Get window frame from pre-captured frames
      let frame = frames[windowId]

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
      // Sort by windowId for deterministic restore order (matches save order)
      let loaded = PersistenceManager.shared.loadMultiWindowState()?.windows ?? []
      pendingRestoreStates = loaded.sorted { $0.windowId.uuidString < $1.windowId.uuidString }
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
      // Sort by windowId for deterministic restore order (matches save order)
      let loaded = PersistenceManager.shared.loadMultiWindowState()?.windows ?? []
      pendingRestoreStates = loaded.sorted { $0.windowId.uuidString < $1.windowId.uuidString }
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

  // MARK: - Menu Bar Support

  /// Simple value-type snapshot for menu bar (no ObservableObject references)
  struct PanelSnapshot {
    let windowId: UUID
    let panelId: UUID
    let title: String
    let isRunning: Bool
  }

  /// Get snapshots of all panels - returns pure value types to avoid reactive updates
  /// All data is captured under lock to avoid accessing ObservableObjects during view updates
  func allPanelSnapshots() -> [PanelSnapshot] {
    lock.lock()
    var result: [PanelSnapshot] = []
    for (windowId, tilingState) in windowStates {
      // Capture panel data while still holding lock
      for (panelId, panel) in tilingState.panels {
        result.append(
          PanelSnapshot(
            windowId: windowId,
            panelId: panelId,
            title: panel.title,
            isRunning: panel.status == .running
          ))
      }
    }
    lock.unlock()
    return result.sorted { $0.title < $1.title }
  }

  /// Get the first available TilingState (for HTTP API)
  func firstTilingState() -> TilingState? {
    lock.lock()
    let state = windowStates.values.first
    lock.unlock()
    return state
  }

  /// Get all panels from all windows (for HTTP API)
  func allPanels() -> [Panel] {
    lock.lock()
    var panels: [Panel] = []
    for (_, tilingState) in windowStates {
      panels.append(contentsOf: tilingState.panels.values)
    }
    lock.unlock()
    return panels
  }

  /// Activate a window and focus a specific panel
  func activateWindowAndFocusPanel(windowId: UUID, panelId: UUID) {
    lock.lock()
    let window = nsWindows[windowId]
    let state = windowStates[windowId]
    lock.unlock()

    DispatchQueue.main.async {
      // Activate the window
      if let window = window {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }

      // Focus the panel
      state?.focusedPanelId = panelId
    }
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
