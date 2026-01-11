import Foundation
import CoreGraphics

/// Application-wide constants
enum Constants {
  // MARK: - HTTP Server

  /// Default port for the HTTP REST API
  static let defaultHTTPPort: UInt16 = 9476

  /// Maximum size for HTTP request bodies in bytes (64KB)
  static let maxHTTPRequestSize: Int = 65536

  // MARK: - Caching

  /// Maximum number of parsed line segments to cache
  static let maxLineSegmentCacheSize = 5000

  /// Percentage of cache to evict when full (20%)
  static let cacheEvictionPercentage = 0.2

  // MARK: - Database

  /// Interval for automatic log cleanup in seconds (5 minutes)
  static let logCleanupIntervalSeconds: TimeInterval = 300

  // MARK: - File Watching

  /// Debounce delay for file system change events in seconds
  static let fileWatchDebounceDelay: TimeInterval = 0.5

  // MARK: - UI

  /// Edge threshold for drag-and-drop operations (25% of dimension)
  static let dragDropEdgeThreshold: Double = 0.25

  /// Minimum split ratio for tiling
  static let minSplitRatio: Double = 0.1

  /// Maximum split ratio for tiling
  static let maxSplitRatio: Double = 0.9

  /// Ratio for minimized (collapsed) panels in a split (~5% for title bar only)
  static let collapsedPanelRatio: CGFloat = 0.05
}
