import Foundation

/// Lightweight workspace info for the workspace list
struct WorkspaceInfo: Identifiable {
  let id: UUID
  var name: String?
  var panelTitles: [String]
  var isOpen: Bool
  var runningCount: Int
  var totalPanelCount: Int

  /// Display name: user-assigned name, or concatenated panel titles
  var displayName: String {
    if let name = name, !name.isEmpty {
      return name
    }
    if panelTitles.isEmpty {
      return "Empty Workspace"
    }
    return panelTitles.joined(separator: " • ")
  }
}
