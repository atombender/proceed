import Foundation

/// Represents a node in the tiling tree
/// Can be either a leaf (containing a panel) or a split (containing two children)
enum TileNode: Identifiable, Equatable {
  case leaf(id: UUID, panelId: UUID)
  case split(
    id: UUID, direction: SplitDirection, first: Box<TileNode>, second: Box<TileNode>, ratio: CGFloat
  )

  var id: UUID {
    switch self {
    case .leaf(let id, _):
      return id
    case .split(let id, _, _, _, _):
      return id
    }
  }

  static func == (lhs: TileNode, rhs: TileNode) -> Bool {
    switch (lhs, rhs) {
    case (.leaf(let id1, let panelId1), .leaf(let id2, let panelId2)):
      return id1 == id2 && panelId1 == panelId2
    case (
      .split(let id1, let dir1, let first1, let second1, let ratio1),
      .split(let id2, let dir2, let first2, let second2, let ratio2)
    ):
      return id1 == id2 && dir1 == dir2 && first1 == first2 && second1 == second2
        && ratio1 == ratio2
    default:
      return false
    }
  }

  /// Find all panel IDs in this subtree
  var allPanelIds: [UUID] {
    switch self {
    case .leaf(_, let panelId):
      return [panelId]
    case .split(_, _, let first, let second, _):
      return first.value.allPanelIds + second.value.allPanelIds
    }
  }

  /// Find the leaf node containing a specific panel
  func findLeaf(panelId: UUID) -> TileNode? {
    switch self {
    case .leaf(_, let pid):
      return pid == panelId ? self : nil
    case .split(_, _, let first, let second, _):
      return first.value.findLeaf(panelId: panelId) ?? second.value.findLeaf(panelId: panelId)
    }
  }

  /// Remove a panel from the tree, returning the modified tree (or nil if this was the only panel)
  func removing(panelId: UUID) -> TileNode? {
    switch self {
    case .leaf(_, let pid):
      return pid == panelId ? nil : self
    case .split(let id, let direction, let first, let second, let ratio):
      let firstResult = first.value.removing(panelId: panelId)
      let secondResult = second.value.removing(panelId: panelId)

      if firstResult == nil && secondResult == nil {
        return nil
      } else if firstResult == nil {
        return secondResult
      } else if secondResult == nil {
        return firstResult
      } else {
        return .split(
          id: id,
          direction: direction,
          first: Box(firstResult!),
          second: Box(secondResult!),
          ratio: ratio
        )
      }
    }
  }

  /// Replace a panel with a new subtree
  func replacing(panelId: UUID, with newNode: TileNode) -> TileNode {
    switch self {
    case .leaf(_, let pid):
      return pid == panelId ? newNode : self
    case .split(let id, let direction, let first, let second, let ratio):
      return .split(
        id: id,
        direction: direction,
        first: Box(first.value.replacing(panelId: panelId, with: newNode)),
        second: Box(second.value.replacing(panelId: panelId, with: newNode)),
        ratio: ratio
      )
    }
  }

  /// Replace a panel with another panel (convenience for panel ID swap)
  func replacing(panelId: UUID, with newPanelId: UUID) -> TileNode {
    switch self {
    case .leaf(let id, let pid):
      return pid == panelId ? .leaf(id: id, panelId: newPanelId) : self
    case .split(let id, let direction, let first, let second, let ratio):
      return .split(
        id: id,
        direction: direction,
        first: Box(first.value.replacing(panelId: panelId, with: newPanelId)),
        second: Box(second.value.replacing(panelId: panelId, with: newPanelId)),
        ratio: ratio
      )
    }
  }

  /// Swap two panels in the tree
  func swapping(panelA: UUID, panelB: UUID) -> TileNode {
    switch self {
    case .leaf(let id, let pid):
      if pid == panelA {
        return .leaf(id: id, panelId: panelB)
      } else if pid == panelB {
        return .leaf(id: id, panelId: panelA)
      }
      return self
    case .split(let id, let direction, let first, let second, let ratio):
      return .split(
        id: id,
        direction: direction,
        first: Box(first.value.swapping(panelA: panelA, panelB: panelB)),
        second: Box(second.value.swapping(panelA: panelA, panelB: panelB)),
        ratio: ratio
      )
    }
  }

  /// Update the ratio of a specific split
  func updatingRatio(splitId: UUID, ratio: CGFloat) -> TileNode {
    switch self {
    case .leaf:
      return self
    case .split(let id, let direction, let first, let second, let currentRatio):
      if id == splitId {
        return .split(
          id: id,
          direction: direction,
          first: first,
          second: second,
          ratio: ratio
        )
      } else {
        return .split(
          id: id,
          direction: direction,
          first: Box(first.value.updatingRatio(splitId: splitId, ratio: ratio)),
          second: Box(second.value.updatingRatio(splitId: splitId, ratio: ratio)),
          ratio: currentRatio
        )
      }
    }
  }

  /// Insert a panel as a split relative to another panel
  func insertingAsSplit(
    newPanelId: UUID,
    relativeTo targetPanelId: UUID,
    position: DropPosition
  ) -> TileNode {
    switch self {
    case .leaf(let id, let pid):
      guard pid == targetPanelId else { return self }

      let newLeaf = TileNode.leaf(id: UUID(), panelId: newPanelId)
      let existingLeaf = TileNode.leaf(id: id, panelId: pid)

      let direction: SplitDirection
      let first: TileNode
      let second: TileNode

      switch position {
      case .left:
        direction = .horizontal
        first = newLeaf
        second = existingLeaf
      case .right:
        direction = .horizontal
        first = existingLeaf
        second = newLeaf
      case .top:
        direction = .vertical
        first = newLeaf
        second = existingLeaf
      case .bottom:
        direction = .vertical
        first = existingLeaf
        second = newLeaf
      case .center:
        // Swap - this case shouldn't happen here
        return self
      }

      return .split(
        id: UUID(),
        direction: direction,
        first: Box(first),
        second: Box(second),
        ratio: 0.5
      )

    case .split(let id, let direction, let first, let second, let ratio):
      return .split(
        id: id,
        direction: direction,
        first: Box(
          first.value.insertingAsSplit(
            newPanelId: newPanelId, relativeTo: targetPanelId, position: position)),
        second: Box(
          second.value.insertingAsSplit(
            newPanelId: newPanelId, relativeTo: targetPanelId, position: position)),
        ratio: ratio
      )
    }
  }

  /// Find redundant drop positions when dragging one panel onto another
  /// Returns positions that would result in no change to the layout
  func redundantDropPositions(dragging draggedPanelId: UUID, onto targetPanelId: UUID) -> Set<
    DropPosition
  > {
    switch self {
    case .leaf:
      return []
    case .split(_, let direction, let first, let second, _):
      // Check if both panels are direct leaf children of this split
      if case .leaf(_, let firstPanelId) = first.value,
        case .leaf(_, let secondPanelId) = second.value
      {
        // Both are direct children - check relationships
        if direction == .horizontal {
          // first is left, second is right
          if firstPanelId == draggedPanelId && secondPanelId == targetPanelId {
            // Dragging left panel onto right panel - "left" zone is redundant
            return [.left]
          } else if secondPanelId == draggedPanelId && firstPanelId == targetPanelId {
            // Dragging right panel onto left panel - "right" zone is redundant
            return [.right]
          }
        } else {
          // first is top, second is bottom
          if firstPanelId == draggedPanelId && secondPanelId == targetPanelId {
            // Dragging top panel onto bottom panel - "top" zone is redundant
            return [.top]
          } else if secondPanelId == draggedPanelId && firstPanelId == targetPanelId {
            // Dragging bottom panel onto top panel - "bottom" zone is redundant
            return [.bottom]
          }
        }
      }

      // Recursively check children
      let fromFirst = first.value.redundantDropPositions(
        dragging: draggedPanelId, onto: targetPanelId)
      if !fromFirst.isEmpty { return fromFirst }

      return second.value.redundantDropPositions(dragging: draggedPanelId, onto: targetPanelId)
    }
  }

  /// Create a 2x2 grid of panels
  static func grid2x2(panels: [UUID]) -> TileNode {
    precondition(panels.count == 4)
    return .split(
      id: UUID(),
      direction: .horizontal,
      first: Box(
        .split(
          id: UUID(),
          direction: .vertical,
          first: Box(.leaf(id: UUID(), panelId: panels[0])),
          second: Box(.leaf(id: UUID(), panelId: panels[2])),
          ratio: 0.5
        )),
      second: Box(
        .split(
          id: UUID(),
          direction: .vertical,
          first: Box(.leaf(id: UUID(), panelId: panels[1])),
          second: Box(.leaf(id: UUID(), panelId: panels[3])),
          ratio: 0.5
        )),
      ratio: 0.5
    )
  }
}

/// Direction of a split
enum SplitDirection: Equatable {
  case horizontal  // Left/Right
  case vertical  // Top/Bottom
}

/// Where a panel is being dropped relative to another
enum DropPosition: Equatable {
  case left
  case right
  case top
  case bottom
  case center  // Swap
}

/// Box wrapper to allow recursive enums
final class Box<T>: Equatable where T: Equatable {
  let value: T

  init(_ value: T) {
    self.value = value
  }

  static func == (lhs: Box<T>, rhs: Box<T>) -> Bool {
    lhs.value == rhs.value
  }
}
