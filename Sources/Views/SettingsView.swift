import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem {
          Label("General", systemImage: "gear")
        }
    }
    .frame(width: 580, height: 340)
  }
}

struct GeneralSettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  @State private var lineHistoryText: String = ""

  var body: some View {
    Form {
      Picker("Appearance", selection: $settingsManager.theme) {
        Text("System").tag(AppTheme.auto)
        Text("Light").tag(AppTheme.light)
        Text("Dark").tag(AppTheme.dark)
      }
      .pickerStyle(.inline)

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

      Toggle("Auto-load direnv if .envrc is present", isOn: $settingsManager.autoDirenv)
        .help(
          "Automatically run commands with 'direnv exec .' when the working directory contains a .envrc file"
        )

      LabeledContent("Log Retention") {
        LogRetentionContent()
      }
      .padding(.top, 8)
    }
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

enum RetentionUnit: String, Codable {
  case hours
  case days
}

#Preview {
  SettingsView()
    .environmentObject(SettingsManager())
}

#Preview {
  SettingsView()
    .environmentObject(SettingsManager())
}
