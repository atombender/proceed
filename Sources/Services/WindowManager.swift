import Foundation
import SwiftUI

// MARK: - Notifications

extension Notification.Name {
  /// Posted when workspace state changes (window opened, closed, panels changed)
  static let workspacesDidChange = Notification.Name("workspacesDidChange")
  /// Posted to request opening a new workspace window
  static let requestNewWorkspace = Notification.Name("requestNewWorkspace")
  /// Posted to request opening the workspace list window
  static let requestOpenWorkspaceList = Notification.Name("requestOpenWorkspaceList")
}

/// Manages multiple window states for persistence
class WindowManager: ObservableObject {
  static let shared = WindowManager()

  /// Incremented when open workspaces change - observers can watch this for updates
  @Published private(set) var workspaceChangeCount: Int = 0

  /// All active tiling states, keyed by window ID
  private var windowStates: [UUID: TilingState] = [:]

  /// Observers for TilingState changes
  private var stateObservers: [UUID: NSObjectProtocol] = [:]
  /// Associated NSWindows for frame tracking
  private var nsWindows: [UUID: NSWindow] = [:]
  private let lock = NSLock()

  /// Saved states waiting to be claimed by windows on restore
  private var pendingRestoreStates: [WindowStateData] = []
  private var hasLoadedPendingStates = false
  /// Workspace IDs that have already been claimed (prevents duplicates)
  private var claimedWorkspaceIds: Set<UUID> = []
  /// Whether we're still in the restoration window
  private var isRestorationActive = true
  /// Specific workspace ID to open (set by WorkspaceManager.openWorkspace)
  private var pendingOpenWorkspaceId: UUID?
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

    // Observe TilingState changes to notify workspace list
    let observer = NotificationCenter.default.addObserver(
      forName: .tilingStateDidChange,
      object: state,
      queue: .main
    ) { [weak self] _ in
      self?.notifyWorkspacesChanged()
    }
    stateObservers[windowId] = observer

    lock.unlock()

    notifyWorkspacesChanged()
  }

  /// Associate an NSWindow with a window ID (called when window becomes available)
  func associateWindow(_ window: NSWindow, with windowId: UUID) {
    lock.lock()
    nsWindows[windowId] = window
    lock.unlock()
  }

  /// Unregister a window when it closes (legacy - kills processes and deletes state)
  func unregister(windowId: UUID) {
    lock.lock()
    if isTerminating {
      lock.unlock()
      return
    }

    // Remove observer
    if let observer = stateObservers.removeValue(forKey: windowId) {
      NotificationCenter.default.removeObserver(observer)
    }

    windowStates.removeValue(forKey: windowId)
    nsWindows.removeValue(forKey: windowId)
    lock.unlock()

    // Also delete from SQLite storage
    PersistenceManager.shared.deleteWindow(windowId)

    notifyWorkspacesChanged()
  }

  /// Close a window without destroying its workspace
  /// Detaches from processes (they continue running) and marks workspace as closed
  func closeWindow(windowId: UUID) {
    lock.lock()
    if isTerminating {
      lock.unlock()
      return
    }

    // Remove observer
    if let observer = stateObservers.removeValue(forKey: windowId) {
      NotificationCenter.default.removeObserver(observer)
    }

    // Get and remove state
    let state = windowStates.removeValue(forKey: windowId)
    nsWindows.removeValue(forKey: windowId)
    lock.unlock()

    // Detach from processes (stop streaming, don't kill)
    state?.detachFromProcesses()

    // Mark workspace as closed in DB (don't delete)
    PersistenceManager.shared.markWorkspaceClosed(windowId)

    notifyWorkspacesChanged()
  }

  /// Signal that workspaces changed - increments counter for Combine observation
  private func notifyWorkspacesChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.workspaceChangeCount += 1
    }
  }

  /// Get live workspace infos for all open workspaces
  func openWorkspaceInfos() -> [WorkspaceInfo] {
    lock.lock()
    let states = windowStates
    lock.unlock()

    var infos: [WorkspaceInfo] = []
    for (windowId, state) in states {
      let panelTitles = state.panels.values.map { $0.title }
      let runningCount = state.panels.values.filter { $0.status == .running }.count
      let info = WorkspaceInfo(
        id: windowId,
        name: state.name,
        panelTitles: Array(panelTitles),
        isOpen: true,
        runningCount: runningCount,
        totalPanelCount: state.panels.count
      )
      infos.append(info)
    }
    return infos
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
          frameHeight: frame?.size.height,
          name: tilingState.name,
          isOpen: true
        ))
    }

    let multiWindowState = MultiWindowState(windows: allWindowStates)
    PersistenceManager.shared.saveMultiWindowState(multiWindowState)
  }

  /// Request to open a specific workspace by ID
  /// The next window created will claim this workspace's state
  func requestOpenWorkspace(id: UUID) {
    lock.lock()
    pendingOpenWorkspaceId = id
    lock.unlock()
  }

  /// Claim the next available saved state for a new window
  func claimNextState() -> WindowStateData? {
    lock.lock()
    defer { lock.unlock() }

    // Check for a specific workspace request first
    if let requestedId = pendingOpenWorkspaceId {
      pendingOpenWorkspaceId = nil

      // Load directly from persistence by ID
      if let state = PersistenceManager.shared.loadWorkspaceState(requestedId) {
        return state
      }
    }

    guard isRestorationActive else { return nil }

    if !hasLoadedPendingStates {
      // Sort by windowId for deterministic restore order (matches save order)
      // Only load workspaces where is_open = 1
      let loaded = PersistenceManager.shared.loadMultiWindowState()?.windows ?? []
      pendingRestoreStates = loaded
        .filter { $0.isOpen }
        .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
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

  /// Get count of pending states (only workspaces that were open)
  func pendingStateCount() -> Int {
    lock.lock()
    defer { lock.unlock() }

    if !hasLoadedPendingStates {
      // Sort by windowId for deterministic restore order (matches save order)
      // Only count workspaces where is_open = 1
      let loaded = PersistenceManager.shared.loadMultiWindowState()?.windows ?? []
      pendingRestoreStates = loaded
        .filter { $0.isOpen }
        .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
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

  // MARK: - Workspace Support

  /// Find if a workspace is open in a window
  /// Returns the window ID and TilingState if found
  func findOpenWorkspace(id: UUID) -> (windowId: UUID, state: TilingState)? {
    lock.lock()
    defer { lock.unlock() }

    // Workspace ID is the same as window ID
    if let state = windowStates[id] {
      return (id, state)
    }
    return nil
  }

  /// Update workspace name for an open window
  func updateWorkspaceName(id: UUID, name: String?) {
    lock.lock()
    let state = windowStates[id]
    lock.unlock()

    DispatchQueue.main.async {
      state?.name = name
    }
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

/// State data for a single window (workspace)
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
  let name: String?
  let isOpen: Bool

  // Codable conformance with defaults for backward compatibility
  enum CodingKeys: String, CodingKey {
    case windowId, panels, layout, lastWorkingDirectory, lastCommand
    case frameX, frameY, frameWidth, frameHeight
    case name, isOpen
  }

  init(
    windowId: UUID, panels: [PanelState], layout: LayoutNode?,
    lastWorkingDirectory: String, lastCommand: String?,
    frameX: CGFloat?, frameY: CGFloat?, frameWidth: CGFloat?, frameHeight: CGFloat?,
    name: String? = nil, isOpen: Bool = true
  ) {
    self.windowId = windowId
    self.panels = panels
    self.layout = layout
    self.lastWorkingDirectory = lastWorkingDirectory
    self.lastCommand = lastCommand
    self.frameX = frameX
    self.frameY = frameY
    self.frameWidth = frameWidth
    self.frameHeight = frameHeight
    self.name = name
    self.isOpen = isOpen
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    windowId = try container.decode(UUID.self, forKey: .windowId)
    panels = try container.decode([PanelState].self, forKey: .panels)
    layout = try container.decodeIfPresent(LayoutNode.self, forKey: .layout)
    lastWorkingDirectory = try container.decode(String.self, forKey: .lastWorkingDirectory)
    lastCommand = try container.decodeIfPresent(String.self, forKey: .lastCommand)
    frameX = try container.decodeIfPresent(CGFloat.self, forKey: .frameX)
    frameY = try container.decodeIfPresent(CGFloat.self, forKey: .frameY)
    frameWidth = try container.decodeIfPresent(CGFloat.self, forKey: .frameWidth)
    frameHeight = try container.decodeIfPresent(CGFloat.self, forKey: .frameHeight)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
  }
}

/// State for all windows
struct MultiWindowState: Codable {
  let windows: [WindowStateData]
}
