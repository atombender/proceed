import Combine
import Foundation
import SwiftUI

/// Manages workspaces - persistent collections of panels that exist independently of windows
class WorkspaceManager: ObservableObject {
  static let shared = WorkspaceManager()

  @Published var workspaces: [WorkspaceInfo] = []

  private var cancellables = Set<AnyCancellable>()
  private let backend = TmuxBackend()

  private init() {
    // Observe WindowManager's workspaceChangeCount using Combine
    // This triggers whenever windows are registered/unregistered
    WindowManager.shared.$workspaceChangeCount
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.rebuildWorkspaceList()
      }
      .store(in: &cancellables)
  }

  /// Rebuild workspace list from database (single source of truth)
  func rebuildWorkspaceList() {
    // Database is the single source of truth for what workspaces exist
    var allWorkspaces = PersistenceManager.shared.loadAllWorkspaceInfos()

    // Enrich with live data from WindowManager for open workspaces
    let liveData = WindowManager.shared.openWorkspaceInfos()
    let liveDataById = Dictionary(uniqueKeysWithValues: liveData.map { ($0.id, $0) })

    for i in allWorkspaces.indices {
      if let live = liveDataById[allWorkspaces[i].id] {
        // Use live data for open workspaces
        allWorkspaces[i].isOpen = true
        allWorkspaces[i].name = live.name
        allWorkspaces[i].panelTitles = live.panelTitles
        allWorkspaces[i].runningCount = live.runningCount
        allWorkspaces[i].totalPanelCount = live.totalPanelCount
      } else {
        allWorkspaces[i].isOpen = false
      }
    }

    // Sort by display name for stable ordering
    allWorkspaces.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    // Update workspaces immediately so open/closed status shows right away
    self.workspaces = allWorkspaces

    // Update running counts for closed workspaces asynchronously (these may still have tmux sessions)
    let closedIds = allWorkspaces.enumerated().filter { !$0.element.isOpen }.map { ($0.offset, $0.element.id) }

    if !closedIds.isEmpty {
      Task { @MainActor in
        var updated = self.workspaces
        for (index, workspaceId) in closedIds {
          // Make sure the index is still valid and refers to the same workspace
          guard index < updated.count, updated[index].id == workspaceId else { continue }
          let runningCount = await countRunningProcesses(for: workspaceId)
          updated[index].runningCount = runningCount
        }
        self.workspaces = updated
      }
    }
  }

  /// Count running tmux sessions for a workspace
  private func countRunningProcesses(for workspaceId: UUID) async -> Int {
    guard let state = PersistenceManager.shared.loadWorkspaceState(workspaceId) else {
      return 0
    }

    var count = 0
    for panel in state.panels {
      if let handleId = panel.handleId {
        if await backend.isSessionRunning(sessionId: handleId) {
          count += 1
        }
      }
    }
    return count
  }

  /// Open a workspace - focus existing window or open new window with saved state
  func openWorkspace(id: UUID) {
    // Check if workspace is already open in a window
    if let (windowId, _) = WindowManager.shared.findOpenWorkspace(id: id) {
      // Focus the existing window
      WindowManager.shared.activateWindowAndFocusPanel(windowId: windowId, panelId: UUID())
      return
    }

    // Mark as open in DB
    PersistenceManager.shared.markWorkspaceOpen(id)

    // Request this specific workspace to be claimed by the next window
    WindowManager.shared.requestOpenWorkspace(id: id)

    // Request ProceedApp to open a new workspace window
    NotificationCenter.default.post(name: .requestNewWorkspace, object: nil)
  }

  /// Delete a workspace - kill all processes and remove from DB
  func deleteWorkspace(id: UUID) {
    // Load workspace state to get process handles
    if let state = PersistenceManager.shared.loadWorkspaceState(id) {
      // Kill all tmux sessions for this workspace
      Task {
        for panel in state.panels {
          if let handleId = panel.handleId {
            await killTmuxSession(handleId)
          }
        }
      }
    }

    // Close window if open
    WindowManager.shared.closeWindow(windowId: id)

    // Delete from DB
    PersistenceManager.shared.deleteWindow(id)
  }

  /// Kill a tmux session by ID
  private func killTmuxSession(_ sessionId: String) async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tmux", "-L", "proceed", "kill-session", "-t", sessionId]

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      // Ignore errors - session may already be dead
    }
  }

  /// Rename a workspace
  func renameWorkspace(id: UUID, name: String?) {
    PersistenceManager.shared.updateWorkspaceName(id, name: name)

    // Update WindowManager if workspace is open
    WindowManager.shared.updateWorkspaceName(id: id, name: name)
  }

  /// Create a new workspace (opens a new window)
  func createWorkspace() {
    NotificationCenter.default.post(name: .requestNewWorkspace, object: nil)
  }
}
