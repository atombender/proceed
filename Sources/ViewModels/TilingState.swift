import Foundation
import SwiftUI

/// Manages the overall tiling state and running processes
class TilingState: ObservableObject {
  @Published var panels: [UUID: Panel] = [:] {
    didSet { WindowManager.shared.scheduleSave() }
  }
  @Published var rootNode: TileNode? {
    didSet { WindowManager.shared.scheduleSave() }
  }
  @Published var dragState: DragState?
  @Published var processes: [UUID: RunningProcess] = [:]
  @Published var focusedPanelId: UUID?

  /// Trigger to show filter bar on focused panel (increments to trigger)
  @Published var showFilterBarTrigger: Int = 0

  /// Last used working directory (persisted for dialog)
  @Published var lastWorkingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

  /// Last used command (persisted for dialog)
  @Published var lastCommand: String = ""

  /// Whether the run process dialog is shown
  @Published var showRunDialog = false

  /// Panel being edited (nil for new process dialog)
  @Published var editingPanelId: UUID?

  /// Stable window ID for frame persistence (restored from saved state or generated new)
  var stableWindowId: UUID?

  /// Pending frame to apply after window is ready
  var pendingFrame: NSRect?

  /// The process backend (tmux-based)
  let backend = TmuxBackend()

  init() {
    // Claim and restore state immediately during init (before view lifecycle)
    if let state = WindowManager.shared.claimNextState() {
      // Use the saved windowId for stable frame persistence
      stableWindowId = state.windowId
      restoreFromWindowStateSync(state)
    } else {
      // New window - generate a stable ID
      stableWindowId = UUID()
    }
  }

  /// Clean up orphaned panel IDs from layout (panels referenced in layout but not in panels dictionary)
  func cleanupOrphanedPanelIds() {
    guard let root = rootNode else { return }

    let layoutPanelIds = Set(root.allPanelIds)
    let actualPanelIds = Set(panels.keys)
    let orphanedIds = layoutPanelIds.subtracting(actualPanelIds)

    if !orphanedIds.isEmpty {
      var newRoot: TileNode? = root
      for orphanedId in orphanedIds {
        newRoot = newRoot?.removing(panelId: orphanedId)
      }
      rootNode = newRoot
    }
  }

  /// Synchronous restore for use during init (before @Published is set up)
  private func restoreFromWindowStateSync(_ state: WindowStateData) {
    lastWorkingDirectory = state.lastWorkingDirectory
    lastCommand = state.lastCommand ?? ""

    // Restore frame
    // Restore panels
    for panelState in state.panels {
      let status: ProcessStatus
      switch panelState.status {
      case .running:
        status = .running
      case .exitedNormally:
        status = .exitedNormally
      case .exitedWithError(let code):
        status = .exitedWithError(code: code)
      }

      var processConfig: ProcessConfig? = nil
      if let configState = panelState.processConfig {
        processConfig = ProcessConfig(
          id: configState.id ?? UUID(),  // Use saved ID for tmux reconnection, or generate new
          name: configState.name,
          command: configState.command,
          workingDirectory: configState.workingDirectory,
          shell: configState.shell,
          autoReloadEnabled: configState.autoReloadEnabled ?? false,
          autoReloadIncludes: configState.autoReloadIncludes ?? [],
          autoReloadExcludes: configState.autoReloadExcludes ?? [],
          autoRestart: configState.autoRestart ?? .auto,
          outputExcludeFilters: configState.outputExcludeFilters ?? [],
          highlightPatterns: configState.highlightPatterns ?? []
        )
        if processConfig?.autoReloadEnabled == true {
            print("TilingState: Restored auto-reload ENABLED for \(configState.name)")
        } else {
            print("TilingState: Restored auto-reload DISABLED for \(configState.name)")
        }
      }

      // Load lines from database asynchronously
      // We initialize with empty lines to unblock the main thread immediately
      // Compute tmuxHandleId from config.id (source of truth) rather than using saved handleId
      let tmuxHandleId: String? = processConfig.map { "proceed-\($0.id.uuidString)" }
      let panel = Panel(
        id: panelState.id,
        title: panelState.title,
        status: status,
        lines: [],  // Empty initially
        processConfig: processConfig,
        tmuxHandleId: tmuxHandleId,
        isMinimized: panelState.isMinimized ?? false,
        rememberedRatio: panelState.rememberedRatio
      )
      panel.isLoadingHistory = true

      panels[panel.id] = panel

      // Kick off async load
      Task.detached(priority: .userInitiated) { [weak panel] in
        guard let panel = panel else { return }
        let limit = await MainActor.run { SettingsManager.shared.maxLineHistory }
        let logEntries = await PersistenceManager.shared.readLogAsync(for: panelState.id, limit: limit)
        let lines = logEntries.map { OutputLine(text: $0.text, timestamp: $0.timestamp, kind: $0.kind) }

        await MainActor.run {
          panel.prependHistory(lines)
          panel.isLoadingHistory = false
        }
      }
    }

    // Restore layout
    if let layoutNode = state.layout {
      rootNode = convertToTileNode(layoutNode)
    }

    // Clean up any orphaned panel IDs from layout
    cleanupOrphanedPanelIds()

    // Reconnect to surviving tmux sessions
    reconnectToExistingProcesses()
  }

  /// Get panel by ID
  func panel(for id: UUID) -> Panel? {
    panels[id]
  }

  /// Number of panels currently displayed
  var panelCount: Int {
    panels.count
  }

  /// Window title based on panel names (e.g., "A • B" or just "A")
  var windowTitle: String {
    guard let root = rootNode else { return "Proceed" }

    // Get panel IDs in layout order
    let panelIds = root.allPanelIds
    let titles = panelIds.compactMap { panels[$0]?.title }

    if titles.isEmpty {
      return "Proceed"
    }
    return titles.joined(separator: " • ")
  }

  /// Clean up all processes when window closes
  func cleanupAllProcesses() {
    for (_, process) in processes {
      process.cleanup(using: backend)
    }
    processes.removeAll()
  }

  // MARK: - Process Management

  /// Run a new process with the given configuration
  func runProcess(config: ProcessConfig) {
    // Remember the working directory and command
    lastWorkingDirectory = config.workingDirectory
    lastCommand = config.command

    // Record in run history
    PersistenceManager.shared.recordRun(
      name: config.name,
      command: config.command,
      workingDirectory: config.workingDirectory,
      shell: config.shell
    )

    // Create a panel for this process (starts as "running" - will be updated if start fails)
    // Set tmuxHandleId upfront since it's deterministic (proceed-{config.id})
    let tmuxHandleId = "proceed-\(config.id.uuidString)"
    let panel = Panel(
      title: config.displayName,
      status: .running,
      processConfig: config,
      tmuxHandleId: tmuxHandleId
    )
    panels[panel.id] = panel

    // Add panel to the tiling layout
    addPanelToLayout(panelId: panel.id)

    // IMPORTANT: Save to database BEFORE starting the process.
    // This ensures the panel exists in our source of truth even if the app crashes
    // before the debounced save completes. The process state is runtime state that
    // can be reconstructed from tmux on restart.
    WindowManager.shared.saveNow()

    // Create and start the process using the backend
    let runningProcess = RunningProcess(
        config: config,
        panel: panel,
        onReloadRequest: { [weak self] in
            self?.reloadProcess(forPanelId: panel.id)
        }
    )
    processes[config.id] = runningProcess

    // Start the process
    runningProcess.start(using: backend)
  }

  /// Add a panel to the layout with auto-arrangement
  private func addPanelToLayout(panelId: UUID) {
    guard let currentRoot = rootNode else {
      // First panel - just a single leaf
      rootNode = .leaf(id: UUID(), panelId: panelId)
      return
    }

    // Get current panel count (before adding)
    let currentCount = currentRoot.allPanelIds.count

    // Strategy:
    // 1 -> 2: Split horizontally (left | right)
    // 2 -> 3: Split the right panel vertically (left | top-right / bottom-right)
    // 3 -> 4: Split the left panel vertically (2x2 grid)
    // 4+: Find the panel with most space and split it

    let newLeaf = TileNode.leaf(id: UUID(), panelId: panelId)

    switch currentCount {
    case 1:
      // Split horizontally: existing | new
      rootNode = .split(
        id: UUID(),
        direction: .horizontal,
        first: Box(currentRoot),
        second: Box(newLeaf),
        ratio: 0.5
      )

    case 2:
      // Split the second (right) panel vertically
      if case .split(let id, let dir, let first, let second, let ratio) = currentRoot,
        dir == .horizontal
      {
        let newSecond = TileNode.split(
          id: UUID(),
          direction: .vertical,
          first: Box(second.value),
          second: Box(newLeaf),
          ratio: 0.5
        )
        rootNode = .split(
          id: id,
          direction: dir,
          first: first,
          second: Box(newSecond),
          ratio: ratio
        )
      } else {
        // Fallback: just split horizontally
        rootNode = .split(
          id: UUID(),
          direction: .horizontal,
          first: Box(currentRoot),
          second: Box(newLeaf),
          ratio: 0.5
        )
      }

    case 3:
      // Split the first (left) panel vertically to make 2x2
      if case .split(let id, let dir, let first, let second, let ratio) = currentRoot,
        dir == .horizontal
      {
        let newFirst = TileNode.split(
          id: UUID(),
          direction: .vertical,
          first: Box(first.value),
          second: Box(newLeaf),
          ratio: 0.5
        )
        rootNode = .split(
          id: id,
          direction: dir,
          first: Box(newFirst),
          second: second,
          ratio: ratio
        )
      } else {
        // Fallback
        rootNode = .split(
          id: UUID(),
          direction: .horizontal,
          first: Box(currentRoot),
          second: Box(newLeaf),
          ratio: 0.5
        )
      }

    default:
      // For 4+, find a leaf and split it
      // Simple strategy: split the last panel added
      if let lastPanelId = currentRoot.allPanelIds.last {
        rootNode = currentRoot.insertingAsSplit(
          newPanelId: panelId,
          relativeTo: lastPanelId,
          position: .bottom
        )
      }
    }
  }

  /// Terminate a process
  func terminateProcess(id: UUID) {
    processes[id]?.terminate(using: backend)
  }

  /// Close a panel, terminating any running process and removing from layout
  func closePanel(id: UUID) {
    // Terminate and cleanup any running process for this panel
    if let process = processes.values.first(where: { $0.panelId == id }) {
      process.cleanup(using: backend)
      processes.removeValue(forKey: process.config.id)
    }

    // Remove from layout
    if let root = rootNode {
      rootNode = root.removing(panelId: id)
    }

    // Remove panel
    panels.removeValue(forKey: id)

    // Delete log file from SQLite
    PersistenceManager.shared.deleteLog(for: id)
  }

  /// Stop a running process (SIGTERM)
  func stopProcess(forPanelId panelId: UUID) {
    if let process = processes.values.first(where: { $0.panelId == panelId }) {
      process.terminate(using: backend)
    }
  }

  /// Restart a stopped process
  func restartProcess(forPanelId panelId: UUID) {
    guard let panel = panels[panelId],
      let oldConfig = panel.processConfig
    else { return }

    // Prevent double-start if already running
    if panel.status == .running {
      return
    }

    // Force view hierarchy to refresh observation on this panel
    // This fixes an issue where OLD panels (restored from saved state) don't
    // properly observe changes after restart
    objectWillChange.send()

    // Clean up any existing process entry
    if let existingProcess = processes.values.first(where: { $0.panelId == panelId }) {
      existingProcess.cleanup(using: backend)
      processes.removeValue(forKey: existingProcess.config.id)
    }

    // Kill any orphaned tmux session synchronously before starting new one
    let oldHandleId = panel.tmuxHandleId

    // Clear the old handle ID so we don't try to kill it again
    panel.tmuxHandleId = nil

    // Create a new process with the same config but new ID
    let newConfig = ProcessConfig(
      name: oldConfig.name,
      command: oldConfig.command,
      workingDirectory: oldConfig.workingDirectory,
      shell: oldConfig.shell,
      autoReloadEnabled: oldConfig.autoReloadEnabled,
      autoReloadIncludes: oldConfig.autoReloadIncludes,
      autoReloadExcludes: oldConfig.autoReloadExcludes,
      autoRestart: oldConfig.autoRestart,
      outputExcludeFilters: oldConfig.outputExcludeFilters,
      highlightPatterns: oldConfig.highlightPatterns
    )

    // Update panel's config and tmuxHandleId
    panel.processConfig = newConfig
    panel.tmuxHandleId = "proceed-\(newConfig.id.uuidString)"

    // IMPORTANT: Save to database BEFORE starting the process.
    // This ensures the new config.id is persisted even if the app crashes.
    WindowManager.shared.saveNow()

    // Create and start new process, reusing the existing panel
    let runningProcess = RunningProcess(
        config: newConfig,
        panel: panel,
        onReloadRequest: { [weak self] in
            self?.reloadProcess(forPanelId: panel.id)
        }
    )
    processes[newConfig.id] = runningProcess

    // Start the process, killing orphan first if needed
    Task {
      // Kill orphaned tmux session first (wait for it)
      if let oldId = oldHandleId {
        _ = try? await backend.kill(
          handle: ProcessHandle(
            id: oldId,
            config: oldConfig,
            pipePath: URL(fileURLWithPath: "/dev/null")
          ))
        // Also stop any lingering pipe reader
        backend.stopOutput(for: oldId)
      }

      // Now start the new process
      await MainActor.run {
        runningProcess.start(using: backend)
      }
    }
  }

  /// Toggle a process: stop if running, start if stopped
  func toggleProcess(forPanelId panelId: UUID) {
    guard let panel = panels[panelId] else { return }

    if panel.status == .running {
      stopProcess(forPanelId: panelId)
    } else {
      restartProcess(forPanelId: panelId)
    }
  }

  /// Reload a process: stop if running, then start
  func reloadProcess(forPanelId panelId: UUID) {
    guard let panel = panels[panelId] else { return }

    if panel.status == .running {
      stopProcess(forPanelId: panelId)

      // Wait for process to stop, then restart
      Task {
        for _ in 0..<100 {
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
          if panel.status != .running {
            break
          }
        }

        await MainActor.run {
          restartProcess(forPanelId: panelId)
        }
      }
    } else {
      restartProcess(forPanelId: panelId)
    }
  }

  /// Update a process configuration
  /// - Returns: true if process needs restart (command/shell/workingDirectory changed)
  func updateProcess(forPanelId panelId: UUID, newConfig: ProcessConfig) {
    guard let panel = panels[panelId],
      let oldConfig = panel.processConfig
    else { return }

    let needsRestart =
      oldConfig.command != newConfig.command || oldConfig.shell != newConfig.shell
      || oldConfig.workingDirectory != newConfig.workingDirectory

    if needsRestart {
      // Track if process was running before edit
      let wasRunning = panel.status == .running

      // Stop existing process if running
      if wasRunning {
        stopProcess(forPanelId: panelId)
      }

      // Update config (and restart only if was running)
      Task {
        // Wait for process to stop if it was running
        if wasRunning {
          for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if panel.status != .running {
              break
            }
          }
        }

        await MainActor.run {
          // Update panel config, tmuxHandleId, and title
          panel.processConfig = newConfig
          panel.tmuxHandleId = "proceed-\(newConfig.id.uuidString)"
          panel.title = newConfig.displayName

          // Remove any existing process entry
          if let existingProcess = processes.values.first(where: { $0.panelId == panelId }) {
            existingProcess.cleanup(using: backend)
            processes.removeValue(forKey: existingProcess.config.id)
          }

          // Update last used values
          lastCommand = newConfig.command
          lastWorkingDirectory = newConfig.workingDirectory

          // IMPORTANT: Save BEFORE starting the process
          WindowManager.shared.saveNow()

          // Only restart if it was previously running
          if wasRunning {
            // Record in run history
            PersistenceManager.shared.recordRun(
              name: newConfig.name,
              command: newConfig.command,
              workingDirectory: newConfig.workingDirectory,
              shell: newConfig.shell
            )

            // Create and start new process
            let runningProcess = RunningProcess(
                config: newConfig,
                panel: panel,
                onReloadRequest: { [weak self] in
                    self?.reloadProcess(forPanelId: panel.id)
                }
            )
            processes[newConfig.id] = runningProcess
            runningProcess.start(using: backend)
          }
        }
      }
    } else {
      // Only name changed - just update the panel title
      panel.processConfig = newConfig
      panel.title = newConfig.displayName
      
      // Update running process config (e.g. for auto-reload settings)
      if let process = processes.values.first(where: { $0.panelId == panelId }) {
          process.updateConfig(newConfig)
      }
      
      WindowManager.shared.scheduleSave()
    }
  }

  // MARK: - Reconnection (after app restart)

  /// Reconnect to processes that survived app restart
  func reconnectToExistingProcesses() {
    Task {
      do {
        let handles = try await backend.listAll()
        var reconnectedHandleIds: Set<String> = []

        for handle in handles {
          let isRunning = await backend.isRunning(handle: handle)
          reconnectedHandleIds.insert(handle.id)

          await MainActor.run {
            // Check if we already have a panel for this process
            // (from restored state) - match by tmux handle ID
            let existingPanel = panels.values.first { panel in
              panel.tmuxHandleId == handle.id
            }

            if let panel = existingPanel {
              // Reconnect to existing panel
              let runningProcess = RunningProcess(
                handle: handle,
                panel: panel,
                isCurrentlyRunning: isRunning,
                onReloadRequest: { [weak self] in
                    self?.reloadProcess(forPanelId: panel.id)
                }
              )
              
              // Ensure process uses the persisted configuration (e.g. auto-reload settings)
              // rather than the potentially stale configuration from the tmux backend metadata
              if let panelConfig = panel.processConfig {
                  runningProcess.config = panelConfig
              }
              
              processes[handle.config.id] = runningProcess

              if isRunning {
                panel.status = .running
              } else {
                panel.status = .exitedNormally
                // Add exit event if not already present (process died while app was closed)
                if panel.lines.last?.kind != .stopped {
                  panel.appendEvent(.stopped, message: "Process exited")
                }
              }

              // Resume streaming (don't load from beginning, we have SQLite logs)
              runningProcess.resume(using: backend, fromBeginning: false)
            }
            // Note: We intentionally don't create panels for orphaned tmux sessions.
            // Each window only reconnects to its own panels from saved state.
          }
        }

        // Mark any panels with tmux handles that weren't found as exited
        let foundIds = reconnectedHandleIds
        await MainActor.run {
          for panel in panels.values {
            if let handleId = panel.tmuxHandleId,
              !foundIds.contains(handleId),
              panel.status == .running
            {
              panel.status = .exitedNormally
              // Add exit event if not already present
              if panel.lines.last?.kind != .stopped {
                panel.appendEvent(.stopped, message: "Process exited")
              }
            }
          }
        }
      } catch {
        // If we can't list sessions (e.g., no tmux server), mark all "running" panels as exited
        await MainActor.run {
          for panel in panels.values {
            if panel.status == .running {
              panel.status = .exitedNormally
              // Add exit event if not already present
              if panel.lines.last?.kind != .stopped {
                panel.appendEvent(.stopped, message: "Process exited")
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Drag and Drop

  /// Start dragging a panel
  func startDrag(panelId: UUID, location: CGPoint) {
    dragState = DragState(
      draggedPanelId: panelId,
      currentLocation: location,
      dropTarget: nil
    )
  }

  /// Update drag location
  func updateDrag(location: CGPoint) {
    dragState?.currentLocation = location
  }

  /// Update drop target
  func updateDropTarget(_ target: DropTarget?) {
    dragState?.dropTarget = target
  }

  /// End dragging
  func endDrag() {
    guard let state = dragState,
      let target = state.dropTarget
    else {
      dragState = nil
      return
    }

    performDrop(
      draggedPanelId: state.draggedPanelId,
      targetPanelId: target.panelId,
      position: target.position
    )

    dragState = nil
  }

  /// Cancel dragging
  func cancelDrag() {
    dragState = nil
  }

  /// Perform the actual drop operation (called internally)
  private func performDrop(draggedPanelId: UUID, targetPanelId: UUID, position: DropPosition) {
    guard draggedPanelId != targetPanelId else { return }
    guard var root = rootNode else { return }

    if position == .center {
      // Swap panels
      root = root.swapping(panelA: draggedPanelId, panelB: targetPanelId)
    } else {
      // First remove the dragged panel from its current location
      guard let newRoot = root.removing(panelId: draggedPanelId) else { return }

      // Then insert it at the new location
      root = newRoot.insertingAsSplit(
        newPanelId: draggedPanelId,
        relativeTo: targetPanelId,
        position: position
      )
    }

    rootNode = root
  }

  /// Perform drop directly without relying on dragState (for native drag/drop)
  /// Handles both same-window and cross-window drops
  func performDropDirectly(draggedPanelId: UUID, targetPanelId: UUID, position: DropPosition) {
    // Check if the panel exists in this TilingState
    if panels[draggedPanelId] != nil {
      // Same-window drop
      performDrop(draggedPanelId: draggedPanelId, targetPanelId: targetPanelId, position: position)
    } else {
      // Cross-window drop - transfer panel from source window
      if WindowManager.shared.transferPanel(panelId: draggedPanelId, to: self) {
        // Panel transferred, now insert into layout
        insertPanelIntoLayout(
          panelId: draggedPanelId,
          relativeTo: targetPanelId,
          position: position
        )
      }
    }

    // Expand the dragged panel if it was minimized - it should fill its new space
    if let panel = panels[draggedPanelId], panel.isMinimized {
      panel.isMinimized = false
      panel.rememberedRatio = nil
    }

    dragState = nil
  }

  /// Insert a panel into the layout at a position relative to another panel
  /// Used for cross-window transfers where the panel doesn't exist in current layout
  private func insertPanelIntoLayout(
    panelId: UUID, relativeTo targetPanelId: UUID, position: DropPosition
  ) {
    guard let root = rootNode else {
      // No layout yet, create single leaf
      rootNode = .leaf(id: UUID(), panelId: panelId)
      return
    }

    // For cross-window transfers, center drop becomes a right split
    // (true swap isn't practical across windows)
    let effectivePosition = position == .center ? .right : position

    rootNode = root.insertingAsSplit(
      newPanelId: panelId,
      relativeTo: targetPanelId,
      position: effectivePosition
    )
  }

  /// Update the ratio of a split
  func updateSplitRatio(splitId: UUID, ratio: CGFloat) {
    guard let root = rootNode else { return }
    rootNode = root.updatingRatio(splitId: splitId, ratio: ratio)
  }

  // MARK: - Panel Minimize/Expand

  /// Check if a panel can be minimized (requires more than one panel)
  func canMinimize(panelId: UUID) -> Bool {
    guard let root = rootNode else { return false }
    return root.allPanelIds.count > 1
  }

  /// Toggle minimize state for a panel
  func toggleMinimize(panelId: UUID) {
    guard let panel = panels[panelId] else { return }

    if panel.isMinimized {
      expandPanel(panelId: panelId)
    } else {
      minimizePanel(panelId: panelId)
    }
  }

  /// Minimize a panel (collapse to title bar only)
  func minimizePanel(panelId: UUID) {
    guard let panel = panels[panelId],
          var root = rootNode,
          !panel.isMinimized else { return }

    // Find parent split info
    guard let parentInfo = root.findParentSplit(panelId: panelId) else { return }

    if parentInfo.direction == .vertical {
      // Already in vertical split - just adjust ratio
      // Remember current ratio
      if let currentRatio = root.findSplitRatio(splitId: parentInfo.splitId) {
        panel.rememberedRatio = parentInfo.isFirst ? currentRatio : (1 - currentRatio)
      }

      // Set collapsed ratio (panel at ~5% height)
      let collapsedRatio: CGFloat = parentInfo.isFirst
        ? Constants.collapsedPanelRatio
        : (1 - Constants.collapsedPanelRatio)
      rootNode = root.updatingRatio(splitId: parentInfo.splitId, ratio: collapsedRatio)

    } else {
      // Horizontal split - need to restructure
      // Find sibling and move panel above it
      if let siblingId = root.findSiblingPanelId(panelId: panelId) {
        // Remember we were in horizontal split for potential future restore
        panel.rememberedRatio = 0.5

        // Restructure: remove panel, then insert above sibling
        if let newRoot = root.removing(panelId: panelId) {
          root = newRoot.insertingAsSplit(
            newPanelId: panelId,
            relativeTo: siblingId,
            position: .top
          )

          // Find the new parent split and set collapsed ratio
          if let newParentInfo = root.findParentSplit(panelId: panelId) {
            let collapsedRatio: CGFloat = newParentInfo.isFirst
              ? Constants.collapsedPanelRatio
              : (1 - Constants.collapsedPanelRatio)
            root = root.updatingRatio(splitId: newParentInfo.splitId, ratio: collapsedRatio)
          }

          rootNode = root
        }
      }
    }

    panel.isMinimized = true
  }

  /// Expand a minimized panel
  func expandPanel(panelId: UUID) {
    guard let panel = panels[panelId],
          let root = rootNode,
          panel.isMinimized else { return }

    // Restore remembered ratio
    if let rememberedRatio = panel.rememberedRatio,
       let parentInfo = root.findParentSplit(panelId: panelId) {
      let restoredRatio = parentInfo.isFirst ? rememberedRatio : (1 - rememberedRatio)
      rootNode = root.updatingRatio(splitId: parentInfo.splitId, ratio: restoredRatio)
    }

    panel.isMinimized = false
    panel.rememberedRatio = nil
  }

  /// Get redundant drop positions for a drag operation
  func redundantDropPositions(dragging draggedPanelId: UUID, onto targetPanelId: UUID) -> Set<
    DropPosition
  > {
    guard let root = rootNode else { return [] }
    return root.redundantDropPositions(dragging: draggedPanelId, onto: targetPanelId)
  }

  // MARK: - Persistence (Legacy single-window support removed)

  /// Convert LayoutNode to TileNode after restore
  private func convertToTileNode(_ node: LayoutNode) -> TileNode {
    switch node {
    case .leaf(let id, let panelId):
      return .leaf(id: id, panelId: panelId)
    case .split(let id, let direction, let first, let second, let ratio):
      let splitDir: SplitDirection = direction == .horizontal ? .horizontal : .vertical
      return .split(
        id: id,
        direction: splitDir,
        first: Box(convertToTileNode(first)),
        second: Box(convertToTileNode(second)),
        ratio: ratio
      )
    }
  }

  /// Restore state from WindowStateData (for multi-window restore)
  func restoreFromWindowState(_ state: WindowStateData) {
    lastWorkingDirectory = state.lastWorkingDirectory
    lastCommand = state.lastCommand ?? ""

    // Restore frame
    if let x = state.frameX, let y = state.frameY,
      let w = state.frameWidth, let h = state.frameHeight
    {
      pendingFrame = NSRect(x: x, y: y, width: w, height: h)
    }

    // Restore panels
    for panelState in state.panels {
      let status: ProcessStatus
      switch panelState.status {
      case .running:
        // Don't trust saved "running" status - will verify via reconnection
        status = .exitedNormally
      case .exitedNormally:
        status = .exitedNormally
      case .exitedWithError(let code):
        status = .exitedWithError(code: code)
      }

      // Restore process config if available
      var processConfig: ProcessConfig? = nil
      if let configState = panelState.processConfig {
        processConfig = ProcessConfig(
          id: configState.id ?? UUID(),  // Use saved ID for tmux reconnection, or generate new
          name: configState.name,
          command: configState.command,
          workingDirectory: configState.workingDirectory,
          shell: configState.shell,
          autoReloadEnabled: configState.autoReloadEnabled ?? false,
          autoReloadIncludes: configState.autoReloadIncludes ?? [],
          autoReloadExcludes: configState.autoReloadExcludes ?? [],
          autoRestart: configState.autoRestart ?? .auto,
          outputExcludeFilters: configState.outputExcludeFilters ?? [],
          highlightPatterns: configState.highlightPatterns ?? []
        )
      }

      // Load lines from database asynchronously
      let panel = Panel(
        id: panelState.id,
        title: panelState.title,
        status: status,
        lines: [], // Empty initially
        processConfig: processConfig,
        tmuxHandleId: panelState.handleId,
        isMinimized: panelState.isMinimized ?? false,
        rememberedRatio: panelState.rememberedRatio
      )
      panel.isLoadingHistory = true

      panels[panel.id] = panel

      // Kick off async load
      Task.detached(priority: .userInitiated) { [weak panel] in
        guard let panel = panel else { return }
        let limit = await MainActor.run { SettingsManager.shared.maxLineHistory }
        let logEntries = await PersistenceManager.shared.readLogAsync(for: panelState.id, limit: limit)
        let lines = logEntries.map { OutputLine(text: $0.text, timestamp: $0.timestamp, kind: $0.kind) }

        await MainActor.run {
          panel.prependHistory(lines)
          panel.isLoadingHistory = false
        }
      }
    }

    // Restore layout
    if let layoutNode = state.layout {
      rootNode = convertToTileNode(layoutNode)
    }

    // Clean up any orphaned panel IDs from layout
    cleanupOrphanedPanelIds()

    // Reconnect to any surviving tmux sessions
    reconnectToExistingProcesses()
  }
}

/// State during a drag operation
struct DragState {
  let draggedPanelId: UUID
  var currentLocation: CGPoint
  var dropTarget: DropTarget?
}

/// Target for a drop operation
struct DropTarget: Equatable {
  let panelId: UUID
  let position: DropPosition
}
