import SwiftUI

struct WorkspaceListView: View {
  @ObservedObject private var workspaceManager = WorkspaceManager.shared
  @State private var deleteConfirmWorkspaceId: UUID?
  @State private var editingWorkspace: WorkspaceInfo?

  var body: some View {
    VStack(spacing: 0) {
      // Toolbar
      HStack {
        Text("Workspaces")
          .font(.headline)

        Spacer()

        Button(action: { workspaceManager.createWorkspace() }) {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Create new workspace")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(NSColor.windowBackgroundColor))

      Divider()

      // Workspace list
      if workspaceManager.workspaces.isEmpty {
        Spacer()
        Text("No workspaces")
          .foregroundColor(.secondary)
        Text("Press + to create one")
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
      } else {
        List {
          ForEach(workspaceManager.workspaces) { workspace in
            WorkspaceRow(
              workspace: workspace,
              onOpen: { workspaceManager.openWorkspace(id: workspace.id) },
              onEdit: { editingWorkspace = workspace },
              onDelete: { deleteConfirmWorkspaceId = workspace.id }
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
          }
        }
        .listStyle(.plain)
      }
    }
    .frame(minWidth: 300, minHeight: 200)
    .onAppear {
      workspaceManager.rebuildWorkspaceList()
      UserDefaults.standard.set(true, forKey: "workspaceListWindowOpen")
    }
    .onDisappear {
      UserDefaults.standard.set(false, forKey: "workspaceListWindowOpen")
    }
    .alert(
      "Delete Workspace?",
      isPresented: Binding(
        get: { deleteConfirmWorkspaceId != nil },
        set: { if !$0 { deleteConfirmWorkspaceId = nil } }
      ),
      presenting: deleteConfirmWorkspaceId
    ) { id in
      Button("Cancel", role: .cancel) {
        deleteConfirmWorkspaceId = nil
      }
      Button("Delete", role: .destructive) {
        workspaceManager.deleteWorkspace(id: id)
        deleteConfirmWorkspaceId = nil
      }
    } message: { _ in
      Text("This will stop all running processes and permanently delete the workspace.")
    }
    .sheet(item: $editingWorkspace) { workspace in
      EditWorkspaceSheet(workspace: workspace) { newName in
        workspaceManager.renameWorkspace(id: workspace.id, name: newName)
      }
    }
  }
}

struct WorkspaceRow: View {
  let workspace: WorkspaceInfo
  let onOpen: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  @State private var isHovered = false
  @State private var editHovered = false
  @State private var trashHovered = false

  var body: some View {
    HStack(spacing: 8) {
      // Status indicator
      Circle()
        .fill(workspace.isOpen ? Color.green : Color.gray)
        .frame(width: 8, height: 8)

      // Name
      Text(workspace.displayName)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer()

      // Edit button
      Button(action: onEdit) {
        Image(systemName: "gearshape")
          .font(.system(size: 11))
          .foregroundColor(editHovered ? .primary : .secondary)
      }
      .buttonStyle(.borderless)
      .onHover { editHovered = $0 }
      .help("Edit workspace")

      // Delete button
      Button(action: onDelete) {
        Image(systemName: "trash")
          .font(.system(size: 11))
          .foregroundColor(trashHovered ? .primary : .secondary)
      }
      .buttonStyle(.borderless)
      .onHover { trashHovered = $0 }
      .help("Delete workspace")
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
    .cornerRadius(6)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(count: 2) { onOpen() }
  }
}

// MARK: - Edit Workspace Sheet

struct EditWorkspaceSheet: View {
  let workspace: WorkspaceInfo
  let onSave: (String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String = ""

  var body: some View {
    VStack(spacing: 16) {
      Text("Edit Workspace")
        .font(.headline)

      TextField("Workspace name", text: $name)
        .textFieldStyle(.roundedBorder)
        .frame(width: 250)

      Text("Leave empty to use panel titles as the name")
        .font(.caption)
        .foregroundColor(.secondary)

      HStack {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          onSave(name.isEmpty ? nil : name)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .onAppear {
      name = workspace.name ?? ""
    }
  }
}

#Preview {
  WorkspaceListView()
    .frame(width: 350, height: 400)
}
