import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem {
          Label("General", systemImage: "gear")
        }
      AutoReloadSettingsView()
        .tabItem {
          Label("Auto Reload", systemImage: "arrow.triangle.2.circlepath")
        }
      AutoRestartSettingsView()
        .tabItem {
          Label("Auto Restart", systemImage: "arrow.clockwise")
        }
    }
    .frame(width: 580, height: 450)
  }
}

struct AutoRestartSettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  var body: some View {
    Form {
      Section {
        Toggle("Enable Auto Restart Globally", isOn: $settingsManager.autoRestartEnabled)
        Text("Automatically restart processes that exit with a failure code.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Backoff Configuration") {
        LabeledContent("Initial Delay") {
          HStack {
            TextField("", value: $settingsManager.restartInitialDelay, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 60)
            Text("seconds")
              .foregroundColor(.secondary)
          }
        }
        
        LabeledContent("Max Delay") {
          HStack {
            TextField("", value: $settingsManager.restartMaxDelay, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 60)
            Text("seconds")
              .foregroundColor(.secondary)
          }
        }
        
        LabeledContent("Reset Interval") {
          HStack {
            TextField("", value: $settingsManager.restartResetTime, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 60)
            Text("seconds")
              .foregroundColor(.secondary)
          }
        }
        Text("Time a process must run successfully to reset the backoff counter.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding()
  }
}

struct AutoReloadSettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  var body: some View {
    Form {
      Section {
        LabeledContent("Debounce Time") {
          HStack {
            TextField("", value: $settingsManager.autoReloadDebounce, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 60)
            Text("seconds")
              .foregroundColor(.secondary)
          }
        }
        Text("Wait this long after file changes before restarting.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer().frame(height: 10)

      Section {
        LabeledContent("Global Include Patterns:") {
          StringListEditor(strings: $settingsManager.globalAutoReloadIncludes, placeholder: "")
        }
        Text("Default is all files if both lists are empty.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer().frame(height: 10)

      Section {
        LabeledContent("Global Exclude Patterns:") {
          StringListEditor(
            strings: $settingsManager.globalAutoReloadExcludes, placeholder: "")
        }
        Text("Exclusions take precedence over inclusions.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding()
  }
}

struct StringListEditor: View {
  @Binding var strings: [String]
  let placeholder: String
  @State private var selection: Set<UUID> = []
  @State private var items: [EditableItem] = []

  // Wrapper to give each string a stable ID for editing
  private struct EditableItem: Identifiable {
    let id = UUID()
    var value: String
  }

  var body: some View {
    VStack(spacing: 6) {
      List(selection: $selection) {
        ForEach($items) { $item in
          TextField("", text: $item.value)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .onSubmit {
              syncToBinding()
            }
        }
        .onDelete { indexSet in
          items.remove(atOffsets: indexSet)
          syncToBinding()
        }
      }
      .frame(height: 100)
      .border(Color.gray.opacity(0.2))
      .background(Color(NSColor.controlBackgroundColor))
      .onAppear {
        syncFromBinding()
      }
      .onChange(of: strings) { _ in
        syncFromBinding()
      }

      HStack {
        Button(action: addEntry) {
          Image(systemName: "plus")
        }

        Button(action: removeSelected) {
          Image(systemName: "minus")
        }
        .disabled(selection.isEmpty)

        Spacer()
      }
    }
  }

  private func syncFromBinding() {
    // Only sync if the content has changed to avoid disrupting editing
    let currentValues = items.map { $0.value }
    if currentValues != strings {
      items = strings.map { EditableItem(value: $0) }
    }
  }

  private func syncToBinding() {
    let trimmed = items.map { $0.value.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    strings = trimmed
  }

  private func addEntry() {
    items.append(EditableItem(value: placeholder))
    syncToBinding()
  }

  private func removeSelected() {
    items.removeAll { selection.contains($0.id) }
    selection.removeAll()
    syncToBinding()
  }
}

struct GeneralSettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  @State private var lineHistoryText: String = ""

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $settingsManager.theme) {
          Text("System").tag(AppTheme.auto)
          Text("Light").tag(AppTheme.light)
          Text("Dark").tag(AppTheme.dark)
        }
        .pickerStyle(.inline)
      }

      Section("Output") {
        LabeledContent("Max Line History") {
          HStack {
            TextField("", text: $lineHistoryText)
              .textFieldStyle(.roundedBorder)
              .frame(width: 80)
              .multilineTextAlignment(.trailing)
              .onAppear {
                lineHistoryText = String(settingsManager.maxLineHistory)
              }
              .onChange(of: lineHistoryText) { newValue in
                if let value = Int(newValue), value > 0 {
                  settingsManager.maxLineHistory = value
                }
              }
            Text("lines")
              .foregroundColor(.secondary)
          }
        }

        LabeledContent("Log Retention") {
          LogRetentionContent()
        }
      }

      Section("Integrations") {
        Toggle("Auto-load direnv if .envrc is present", isOn: $settingsManager.autoDirenv)
          .help(
            "Automatically run commands with 'direnv exec .' when the working directory contains a .envrc file"
          )

        Toggle("Show menu bar icon", isOn: $settingsManager.showMenuBarExtra)
          .help("Show Proceed in the menu bar for quick access to panels")
      }

      Section("HTTP API") {
        Toggle("Enable HTTP API", isOn: $settingsManager.httpAPIEnabled)
          .help("Enable local HTTP API for command-line tools and integrations")

        if settingsManager.httpAPIEnabled {
          LabeledContent("Port") {
            TextField("", text: Binding(
              get: { String(settingsManager.httpAPIPort) },
              set: { if let val = UInt16($0) { settingsManager.httpAPIPort = val } }
            ))
              .textFieldStyle(.roundedBorder)
              .frame(width: 80)
              .multilineTextAlignment(.trailing)
          }
          .help("Port for the HTTP API server (requires restart)")
        }
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}

struct LogRetentionContent: View {
  @EnvironmentObject var settingsManager: SettingsManager

  @State private var retentionValueText: String = ""

  private var hasLimit: Bool {
    settingsManager.logRetentionSeconds != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // No limit option
      HStack {
        Image(systemName: hasLimit ? "circle" : "circle.inset.filled")
          .foregroundColor(.accentColor)
        Text("No limit")
      }
      .contentShape(Rectangle())
      .onTapGesture {
        settingsManager.logRetentionSeconds = nil
      }

      // Keep for X hours/days option
      HStack {
        Image(systemName: hasLimit ? "circle.inset.filled" : "circle")
          .foregroundColor(.accentColor)
          .onTapGesture {
            if !hasLimit {
              settingsManager.logRetentionSeconds = 7 * 24 * 3600
              settingsManager.logRetentionUnit = .days
              retentionValueText = "7"
            }
          }
        Text("Keep for")

        TextField("", text: $retentionValueText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 50)
          .multilineTextAlignment(.trailing)
          .disabled(!hasLimit)
          .onAppear {
            updateRetentionText()
          }
          .onChange(of: retentionValueText) { newValue in
            if hasLimit, let value = Int(newValue), value > 0 {
              updateRetentionSeconds(value: value)
            }
          }
          .onChange(of: settingsManager.logRetentionSeconds) { _ in
            updateRetentionText()
          }

        Picker("", selection: $settingsManager.logRetentionUnit) {
          Text("Hours").tag(RetentionUnit.hours)
          Text("Days").tag(RetentionUnit.days)
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
        .disabled(!hasLimit)
        .onChange(of: settingsManager.logRetentionUnit) { _ in
          if hasLimit, let value = Int(retentionValueText), value > 0 {
            updateRetentionSeconds(value: value)
          }
        }
      }
    }
  }

  private func updateRetentionText() {
    guard let seconds = settingsManager.logRetentionSeconds else {
      retentionValueText = ""
      return
    }
    let value: Int
    switch settingsManager.logRetentionUnit {
    case .hours:
      value = seconds / 3600
    case .days:
      value = seconds / (24 * 3600)
    }
    retentionValueText = String(max(1, value))
  }

  private func updateRetentionSeconds(value: Int) {
    switch settingsManager.logRetentionUnit {
    case .hours:
      settingsManager.logRetentionSeconds = value * 3600
    case .days:
      settingsManager.logRetentionSeconds = value * 24 * 3600
    }
  }
}

// RetentionUnit moved to SharedTypes.swift

#Preview {
  SettingsView()
    .environmentObject(SettingsManager())
}

#Preview {
  SettingsView()
    .environmentObject(SettingsManager())
}
