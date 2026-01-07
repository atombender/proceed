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
    .frame(width: 450, height: 250)
  }
}

struct GeneralSettingsView: View {
  @EnvironmentObject var settingsManager: SettingsManager

  private let historyOptions = [1000, 5000, 10000, 25000, 50000, 100000]

  var body: some View {
    Form {
      Picker("Appearance", selection: $settingsManager.theme) {
        Text("System").tag(AppTheme.auto)
        Text("Light").tag(AppTheme.light)
        Text("Dark").tag(AppTheme.dark)
      }
      .pickerStyle(.inline)

      Picker("Max Line History", selection: $settingsManager.maxLineHistory) {
        ForEach(historyOptions, id: \.self) { value in
          Text(formatLineCount(value)).tag(value)
        }
      }
      .pickerStyle(.menu)

      Toggle("Auto-load direnv if .envrc is present", isOn: $settingsManager.autoDirenv)
        .help(
          "Automatically run commands with 'direnv exec .' when the working directory contains a .envrc file"
        )
    }
    .padding()
  }

  private func formatLineCount(_ count: Int) -> String {
    if count >= 1000 {
      return "\(count / 1000)k lines"
    }
    return "\(count) lines"
  }
}

#Preview {
  SettingsView()
    .environmentObject(SettingsManager())
}
