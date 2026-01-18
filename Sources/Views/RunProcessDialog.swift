import SwiftUI

struct RunProcessDialog: View {
  @ObservedObject var tilingState: TilingState
  @Environment(\.dismiss) private var dismiss

  @State private var name: String = ""
  @State private var command: String = ""
  @State private var workingDirectory: String = ""
  @State private var shell: String = ProcessConfig.defaultShell
  @State private var recentRuns: [PersistenceManager.RunHistoryEntry] = []

  // Auto Reload state
  @State private var autoReloadEnabled: Bool = false
  @State private var autoReloadIncludes: [String] = []
  @State private var autoReloadExcludes: [String] = []

  // Output filters state
  @State private var outputExcludeFilters: [String] = []

  // Highlight patterns state
  @State private var highlightPatterns: [String] = []

  /// The panel being edited (nil for new process)
  private var editingPanel: Panel? {
    guard let panelId = tilingState.editingPanelId else { return nil }
    return tilingState.panels[panelId]
  }

  private var isEditing: Bool {
    editingPanel != nil
  }

  private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    VStack(spacing: 0) {
      // Header
      Text(isEditing ? "Edit Process" : "Run Process")
        .font(.headline)
        .padding()

      Divider()

      // Form
      Form {
        // Recent runs picker (only for new processes, not editing)
        if !isEditing && !recentRuns.isEmpty {
          Picker(
            "Recent:",
            selection: Binding(
              get: { Optional<Int64>.none },
              set: { newValue in
                if let id = newValue,
                  let entry = recentRuns.first(where: { $0.id == id })
                {
                  selectRecentRun(entry)
                }
              }
            )
          ) {
            Text("Select a recent run...").tag(Optional<Int64>.none)
            ForEach(recentRuns) { entry in
              Text(formatRecentRun(entry))
                .tag(Optional(entry.id))
            }
          }
          .pickerStyle(.menu)
        }

        TextField("Command:", text: $command)
          .textFieldStyle(.roundedBorder)

        TextField("Name (optional):", text: $name)
          .textFieldStyle(.roundedBorder)

        HStack {
          TextField("Working Directory:", text: $workingDirectory)
            .textFieldStyle(.roundedBorder)

          Button("Browse...") {
            browseDirectory()
          }
        }

        TextField("Shell:", text: $shell)
          .textFieldStyle(.roundedBorder)

        Section("Auto Reload") {
          Toggle("Enable Auto Reload", isOn: $autoReloadEnabled)

          LabeledContent("Include Patterns (Glob):") {
            StringListEditor(strings: $autoReloadIncludes, placeholder: "")
          }

          LabeledContent("Exclude Patterns (Glob):") {
            StringListEditor(strings: $autoReloadExcludes, placeholder: "")
          }
        }

        Section("Output Filters") {
          LabeledContent("Exclude Patterns (Regex):") {
            StringListEditor(strings: $outputExcludeFilters, placeholder: "e.g. ^DEBUG:")
          }
        }

        Section("Highlighting") {
          LabeledContent("Highlight Patterns (Regex):") {
            StringListEditor(strings: $highlightPatterns, placeholder: "e.g. ERROR|WARN")
          }
        }
      }
      .padding()

      Divider()

      // Buttons
      HStack {
        Spacer()

        Button("Cancel") {
          tilingState.editingPanelId = nil
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button(isEditing ? "Save" : "Run") {
          if isEditing {
            saveProcess()
          } else {
            runProcess()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding()
    }
    .frame(minWidth: 500, idealWidth: 550, maxWidth: 700, minHeight: 500)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      if let panel = editingPanel, let config = panel.processConfig {
        // Editing mode - populate from existing config
        name = config.name
        command = config.command
        workingDirectory = config.workingDirectory
        shell = config.shell
        autoReloadEnabled = config.autoReloadEnabled
        autoReloadIncludes = config.autoReloadIncludes
        autoReloadExcludes = config.autoReloadExcludes
        outputExcludeFilters = config.outputExcludeFilters
        highlightPatterns = config.highlightPatterns
      } else {
        // New process mode - use last values and load recent runs
        workingDirectory = tilingState.lastWorkingDirectory
        command = tilingState.lastCommand
        recentRuns = PersistenceManager.shared.getRecentRuns(limit: 10)
      }
    }
  }

  private func formatRecentRun(_ entry: PersistenceManager.RunHistoryEntry) -> String {
    let timeAgo = Self.relativeTimeFormatter.localizedString(
      for: entry.startedAt, relativeTo: Date())
    let displayName = entry.name.isEmpty ? entry.command : entry.name
    let truncatedCommand =
      entry.command.count > 40
      ? String(entry.command.prefix(37)) + "..."
      : entry.command

    if entry.name.isEmpty {
      return "\(truncatedCommand) (\(timeAgo))"
    } else {
      return "\(displayName): \(truncatedCommand) (\(timeAgo))"
    }
  }

  private func selectRecentRun(_ entry: PersistenceManager.RunHistoryEntry) {
    name = entry.name
    command = entry.command
    workingDirectory = entry.workingDirectory
    shell = entry.shell

    // Restore auto-reload settings
    autoReloadEnabled = entry.autoReloadEnabled
    autoReloadIncludes = entry.autoReloadIncludes
    autoReloadExcludes = entry.autoReloadExcludes

    // Restore output filters and highlights
    outputExcludeFilters = entry.outputExcludeFilters
    highlightPatterns = entry.highlightPatterns
  }

  private func browseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: workingDirectory)

    if panel.runModal() == .OK, let url = panel.url {
      workingDirectory = url.path
    }
  }

  private func runProcess() {
    let config = ProcessConfig(
      name: name,
      command: command,
      workingDirectory: workingDirectory,
      shell: shell,
      autoReloadEnabled: autoReloadEnabled,
      autoReloadIncludes: autoReloadIncludes,
      autoReloadExcludes: autoReloadExcludes,
      outputExcludeFilters: outputExcludeFilters,
      highlightPatterns: highlightPatterns
    )

    tilingState.runProcess(config: config)
    dismiss()
  }

  private func saveProcess() {
    guard let panelId = tilingState.editingPanelId,
      let existingConfig = editingPanel?.processConfig
    else { return }

    // Preserve existing config.id for non-restart edits (name/filter changes).
    // If restart is needed, updateProcess() will create a new ID to avoid race conditions.
    let newConfig = ProcessConfig(
      id: existingConfig.id,
      name: name,
      command: command,
      workingDirectory: workingDirectory,
      shell: shell,
      autoReloadEnabled: autoReloadEnabled,
      autoReloadIncludes: autoReloadIncludes,
      autoReloadExcludes: autoReloadExcludes,
      outputExcludeFilters: outputExcludeFilters,
      highlightPatterns: highlightPatterns
    )

    tilingState.updateProcess(forPanelId: panelId, newConfig: newConfig)
    tilingState.editingPanelId = nil
    dismiss()
  }
}

#Preview {
  RunProcessDialog(tilingState: TilingState())
}
