import AppKit
import SwiftUI

struct ContentView: View {
  @StateObject private var tilingState = TilingState()
  @ObservedObject private var httpServer = HTTPServer.shared

  var body: some View {
    ZStack {
      // Main tiling content
      if let root = tilingState.rootNode {
        TilingContainerView(node: root)
          .padding(8)
      } else {
        emptyState
      }

      // Drag indicator overlay
      if let dragState = tilingState.dragState {
        DragIndicator(dragState: dragState)
      }
    }
    .environmentObject(tilingState)
    .frame(minWidth: 600, minHeight: 400)
    .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    .toolbar {
      ToolbarItem(placement: .automatic) {
        httpAPIStatusPill
      }
    }
    .onDrop(of: [.text], isTargeted: nil) { _ in
      // Catch-all drop handler to clear drag state when drop ends anywhere
      tilingState.cancelDrag()
      return false
    }
    .sheet(isPresented: $tilingState.showRunDialog) {
      RunProcessDialog(tilingState: tilingState)
    }
    .focusedSceneValue(\.tilingState, tilingState)
    .background {
      // Window accessor to track NSWindow and apply frame
      WindowAccessor(tilingState: tilingState, windowTitle: tilingState.windowTitle)
    }
    .onAppear {
      // Register with window manager using the stable ID
      if let stableId = tilingState.stableWindowId {
        WindowManager.shared.register(windowId: stableId, state: tilingState)
      }
    }
    .onDisappear {
      // Clean up all processes when window closes
      tilingState.cleanupAllProcesses()

      // Unregister when window closes
      if let stableId = tilingState.stableWindowId {
        WindowManager.shared.unregister(windowId: stableId)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 20) {
      Spacer()

      Text("\u{2318}R: Run process")
        .font(.system(size: 24, weight: .light, design: .default))
        .foregroundColor(.secondary.opacity(0.5))

      Spacer()
    }
  }

  @ViewBuilder
  private var httpAPIStatusPill: some View {
    if httpServer.isRunning, let url = httpServer.url {
      HStack(spacing: 4) {
        Circle()
          .fill(Color.green)
          .frame(width: 6, height: 6)
        Text(url)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundColor(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
      .cornerRadius(4)
      .help("HTTP API is running. Click to copy URL.")
      .onTapGesture {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
      }
    } else {
      HStack(spacing: 4) {
        Circle()
          .fill(Color.gray)
          .frame(width: 6, height: 6)
        Text("HTTP API: off")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.secondary.opacity(0.6))
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
      .cornerRadius(4)
      .help("HTTP API is disabled. Enable in Settings.")
    }
  }
}

struct DragIndicator: View {
  let dragState: DragState

  var body: some View {
    // Visual indicator showing what's being dragged
    // This floats near the cursor during drag
    GeometryReader { geometry in
      if let position = dragState.dropTarget?.position {
        Text(positionLabel(position))
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.blue.opacity(0.8))
          .cornerRadius(4)
          .position(
            x: min(max(dragState.currentLocation.x + 20, 50), geometry.size.width - 50),
            y: min(max(dragState.currentLocation.y - 20, 20), geometry.size.height - 20)
          )
      }
    }
    .allowsHitTesting(false)
  }

  private func positionLabel(_ position: DropPosition) -> String {
    switch position {
    case .left: return "Left"
    case .right: return "Right"
    case .top: return "Top"
    case .bottom: return "Bottom"
    case .center: return "Swap"
    }
  }
}

/// NSViewRepresentable to access the hosting NSWindow
struct WindowAccessor: NSViewRepresentable {
  let tilingState: TilingState
  let windowTitle: String

  func makeNSView(context: Context) -> WindowAccessorView {
    let view = WindowAccessorView()
    view.stableWindowId = tilingState.stableWindowId
    view.pendingFrame = tilingState.pendingFrame
    view.windowTitle = windowTitle
    return view
  }

  func updateNSView(_ nsView: WindowAccessorView, context: Context) {
    // Update window title when panels change
    nsView.windowTitle = windowTitle
    nsView.window?.title = windowTitle
  }
}

/// Custom NSView that sets window autosave name for frame persistence
class WindowAccessorView: NSView {
  var stableWindowId: UUID?
  var pendingFrame: NSRect?
  var windowTitle: String = "Proceed"

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window = window, let stableId = stableWindowId else { return }

    WindowManager.shared.associateWindow(window, with: stableId)

    // Set window title
    window.title = windowTitle

    // Prioritize explicit pending frame from saved state
    if let frame = pendingFrame {
      window.setFrame(frame, display: true)
    } else {
      // Use stable window ID as autosave name - this persists across launches
      let autosaveName = "ProceedWindow-\(stableId.uuidString)"
      window.setFrameAutosaveName(autosaveName)
      window.setFrameUsingName(autosaveName)
    }
  }
}

#Preview {
  ContentView()
    .frame(width: 1000, height: 700)
}
