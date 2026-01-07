import SwiftUI
import UniformTypeIdentifiers

struct TilingContainerView: View {
    let node: TileNode
    @EnvironmentObject var tilingState: TilingState

    var body: some View {
        GeometryReader { geometry in
            TileNodeView(node: node, size: geometry.size)
                .environmentObject(tilingState)
        }
    }
}

/// Separate view to handle recursive tile rendering with AnyView to prevent type explosion
struct TileNodeView: View {
    let node: TileNode
    let size: CGSize
    @EnvironmentObject var tilingState: TilingState

    var body: some View {
        nodeContent
    }

    @ViewBuilder
    private var nodeContent: some View {
        switch node {
        case .leaf(_, let panelId):
            leafView(panelId: panelId)
        case .split(let id, let direction, let first, let second, let ratio):
            SplitView(
                splitId: id,
                direction: direction,
                first: first.value,
                second: second.value,
                ratio: ratio,
                size: size
            )
        }
    }

    @ViewBuilder
    private func leafView(panelId: UUID) -> some View {
        if let panel = tilingState.panel(for: panelId) {
            PanelWithDropZones(panel: panel)
        } else {
            Color.red.opacity(0.3)
                .overlay(Text("Missing panel"))
        }
    }
}

/// Split view that renders two child nodes with a resizable divider
struct SplitView: View {
    let splitId: UUID
    let direction: SplitDirection
    let first: TileNode
    let second: TileNode
    let ratio: CGFloat
    let size: CGSize
    @EnvironmentObject var tilingState: TilingState
    @State private var isDraggingDivider = false

    private let dividerThickness: CGFloat = 6
    private let dividerVisualThickness: CGFloat = 2

    var body: some View {
        if direction == .horizontal {
            HStack(spacing: 0) {
                TileNodeView(node: first, size: firstSize)
                    .frame(width: firstSize.width)

                divider

                TileNodeView(node: second, size: secondSize)
                    .frame(width: secondSize.width)
            }
        } else {
            VStack(spacing: 0) {
                TileNodeView(node: first, size: firstSize)
                    .frame(height: firstSize.height)

                divider

                TileNodeView(node: second, size: secondSize)
                    .frame(height: secondSize.height)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(isDraggingDivider ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(
                width: direction == .horizontal ? dividerThickness : nil,
                height: direction == .vertical ? dividerThickness : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDraggingDivider = true
                        let delta: CGFloat
                        let totalSize: CGFloat

                        if direction == .horizontal {
                            delta = value.translation.width
                            totalSize = size.width - dividerThickness
                        } else {
                            delta = value.translation.height
                            totalSize = size.height - dividerThickness
                        }

                        let currentFirstSize = totalSize * ratio
                        let newFirstSize = currentFirstSize + delta
                        let newRatio = max(0.1, min(0.9, newFirstSize / totalSize))

                        tilingState.updateSplitRatio(splitId: splitId, ratio: newRatio)
                    }
                    .onEnded { _ in
                        isDraggingDivider = false
                    }
            )
    }

    private var firstSize: CGSize {
        let available = direction == .horizontal
            ? size.width - dividerThickness
            : size.height - dividerThickness

        if direction == .horizontal {
            return CGSize(width: available * ratio, height: size.height)
        } else {
            return CGSize(width: size.width, height: available * ratio)
        }
    }

    private var secondSize: CGSize {
        let available = direction == .horizontal
            ? size.width - dividerThickness
            : size.height - dividerThickness

        if direction == .horizontal {
            return CGSize(width: available * (1 - ratio), height: size.height)
        } else {
            return CGSize(width: size.width, height: available * (1 - ratio))
        }
    }
}

struct PanelWithDropZones: View {
    @ObservedObject var panel: Panel
    @EnvironmentObject var tilingState: TilingState
    @State private var dropPosition: DropPosition?
    @State private var viewSize: CGSize = .zero

    private var isDraggingThisPanel: Bool {
        tilingState.dragState?.draggedPanelId == panel.id
    }

    var body: some View {
        PanelView(panel: panel)
            .background(GeometryReader { geo in
                Color.clear.onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { newSize in viewSize = newSize }
            })
            .overlay(dropHighlight)
            .onDrop(of: [.text], delegate: PanelDropDelegate(
                panelId: panel.id,
                tilingState: tilingState,
                dropPosition: $dropPosition,
                viewSize: viewSize
            ))
            .onReceive(panel.objectWillChange) { _ in
                // Explicit subscription ensures view updates for restored panels
            }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if let position = dropPosition, !isDraggingThisPanel {
            GeometryReader { geo in
                dropHighlightRect(for: position, in: geo.size)
            }
        }
    }

    private func dropHighlightRect(for position: DropPosition, in size: CGSize) -> some View {
        let edgeThreshold: CGFloat = 0.25
        let rect: CGRect
        switch position {
        case .left:
            rect = CGRect(x: 0, y: 0, width: size.width * edgeThreshold, height: size.height)
        case .right:
            rect = CGRect(x: size.width * (1 - edgeThreshold), y: 0, width: size.width * edgeThreshold, height: size.height)
        case .top:
            rect = CGRect(x: 0, y: 0, width: size.width, height: size.height * edgeThreshold)
        case .bottom:
            rect = CGRect(x: 0, y: size.height * (1 - edgeThreshold), width: size.width, height: size.height * edgeThreshold)
        case .center:
            rect = CGRect(x: size.width * edgeThreshold, y: size.height * edgeThreshold,
                         width: size.width * (1 - 2 * edgeThreshold), height: size.height * (1 - 2 * edgeThreshold))
        }
        return Rectangle()
            .fill(Color.blue.opacity(0.3))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

struct PanelDropDelegate: DropDelegate {
    let panelId: UUID
    let tilingState: TilingState
    @Binding var dropPosition: DropPosition?
    let viewSize: CGSize
    private let edgeThreshold: CGFloat = 0.25

    func dropEntered(info: DropInfo) {
        updateDropPosition(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropPosition(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropPosition = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let position = dropPosition else {
            print("DEBUG: No drop position")
            dropPosition = nil
            return false
        }

        // Try multiple UTTypes
        var providers = info.itemProviders(for: [.plainText])
        if providers.isEmpty {
            providers = info.itemProviders(for: [.text])
        }
        if providers.isEmpty {
            providers = info.itemProviders(for: [.utf8PlainText])
        }

        print("DEBUG: Found \(providers.count) providers, position: \(position)")

        guard let provider = providers.first else {
            print("DEBUG: No provider found")
            dropPosition = nil
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, error in
            if let error = error {
                print("DEBUG: Error loading object: \(error)")
                return
            }

            guard let uuidString = object as? String else {
                print("DEBUG: Object is not a string: \(String(describing: object))")
                return
            }

            print("DEBUG: Got UUID string: \(uuidString)")

            guard let draggedPanelId = UUID(uuidString: uuidString) else {
                print("DEBUG: Invalid UUID")
                return
            }

            guard draggedPanelId != self.panelId else {
                print("DEBUG: Same panel, ignoring")
                return
            }

            DispatchQueue.main.async {
                print("DEBUG: Performing drop")
                self.tilingState.performDropDirectly(
                    draggedPanelId: draggedPanelId,
                    targetPanelId: self.panelId,
                    position: position
                )
            }
        }

        dropPosition = nil
        return true
    }

    private func updateDropPosition(info: DropInfo) {
        let location = info.location
        guard viewSize.width > 0 && viewSize.height > 0 else {
            dropPosition = .center
            return
        }

        let relX = location.x / viewSize.width
        let relY = location.y / viewSize.height

        let rawPosition: DropPosition
        if relX < edgeThreshold {
            rawPosition = .left
        } else if relX > (1 - edgeThreshold) {
            rawPosition = .right
        } else if relY < edgeThreshold {
            rawPosition = .top
        } else if relY > (1 - edgeThreshold) {
            rawPosition = .bottom
        } else {
            rawPosition = .center
        }

        // Check if this position is redundant (would result in no change)
        if let draggedPanelId = tilingState.dragState?.draggedPanelId {
            let redundant = tilingState.redundantDropPositions(dragging: draggedPanelId, onto: panelId)
            if redundant.contains(rawPosition) {
                dropPosition = nil
                return
            }
        }

        dropPosition = rawPosition
    }
}
