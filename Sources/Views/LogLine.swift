import Foundation
import AppKit

// MARK: - Data Types

/// Represents a text selection range
struct TextSelection: Equatable {
  var startLine: Int
  var startChar: Int
  var endLine: Int
  var endChar: Int

  /// Normalized so start <= end
  var normalized: TextSelection {
    if startLine > endLine || (startLine == endLine && startChar > endChar) {
      return TextSelection(
        startLine: endLine, startChar: endChar, endLine: startLine, endChar: startChar)
    }
    return self
  }

  var isEmpty: Bool {
    startLine == endLine && startChar == endChar
  }
}

/// A single logical line with its content
struct LogLine {
  let id: UUID
  let timestamp: Date
  let attributedContent: NSAttributedString
  let isMetaLine: Bool
}

// MARK: - OutputLine to LogLine Conversion

extension LogLine {
  /// Create a LogLine from an OutputLine
  static func from(_ outputLine: OutputLine, font: NSFont) -> LogLine {
    let attrString = NSMutableAttributedString()

    for segment in outputLine.segments {
      switch segment {
      case .text(let text, let style):
        var attrs: [NSAttributedString.Key: Any] = [.font: font]

        // Foreground color
        if let fg = style.foreground {
          attrs[.foregroundColor] = NSColor(fg)
        } else {
          attrs[.foregroundColor] = NSColor.labelColor
        }

        // Background color
        if let bg = style.background {
          attrs[.backgroundColor] = NSColor(bg)
        }

        // Bold
        if style.bold {
          let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
          attrs[.font] = boldFont
        }

        // Italic
        if style.italic {
          let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
          attrs[.font] = italicFont
        }

        // Underline
        if style.underline {
          attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        // Dim
        if style.dim {
          attrs[.foregroundColor] = NSColor.secondaryLabelColor
        }

        attrString.append(NSAttributedString(string: text, attributes: attrs))

      case .nonPrintable(let name):
        // Render non-printables as small badges
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.75, weight: .medium),
          .foregroundColor: NSColor.secondaryLabelColor,
          .backgroundColor: NSColor.quaternaryLabelColor,
        ]
        attrString.append(NSAttributedString(string: " \(name) ", attributes: attrs))
      }
    }

    return LogLine(
      id: outputLine.id,
      timestamp: outputLine.timestamp,
      attributedContent: attrString,
      isMetaLine: outputLine.isMeta
    )
  }
}
