import SwiftUI

class SettingsManager: ObservableObject {
  static let shared = SettingsManager()

  @Published var theme: AppTheme = .auto {
    didSet {
      saveSettings()
    }
  }

  @Published var fontSize: CGFloat = 12 {
    didSet {
      saveSettings()
    }
  }

  @Published var maxLineHistory: Int = 10000 {
    didSet {
      saveSettings()
    }
  }

  @Published var autoDirenv: Bool = false {
    didSet {
      saveSettings()
    }
  }

  init() {
    loadSettings()
  }

  private func loadSettings() {
    if let settings = PersistenceManager.shared.loadSettings() {
      self.theme = settings.theme
      self.fontSize = settings.fontSize > 0 ? settings.fontSize : 12
      self.maxLineHistory = settings.maxLineHistory > 0 ? settings.maxLineHistory : 10000
      self.autoDirenv = settings.autoDirenv
    }
  }

  private func saveSettings() {
    let settings = GlobalSettings(
      theme: theme, fontSize: fontSize, maxLineHistory: maxLineHistory, autoDirenv: autoDirenv)
    PersistenceManager.shared.saveSettings(settings)
  }

  var colorScheme: ColorScheme? {
    switch theme {
    case .light:
      return .light
    case .dark:
      return .dark
    case .auto:
      return nil
    }
  }
}
