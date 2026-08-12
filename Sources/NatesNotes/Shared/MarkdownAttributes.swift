import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension NSAttributedString.Key {
    /// Marks syntax characters that should collapse to zero width when the caret
    /// is elsewhere. The layout manager turns these into null glyphs.
    static let hiddenMD = NSAttributedString.Key("nn.hiddenMD")
    /// Per-line ornament drawn by the text view (bullet, checkbox, rule, image…).
    static let lineDecoration = NSAttributedString.Key("nn.lineDecoration")
    /// Spans a whole fenced block so its background can be drawn as one slab.
    static let codeBlock = NSAttributedString.Key("nn.codeBlock")
    static let inlineCode = NSAttributedString.Key("nn.inlineCode")
    static let quoteBlock = NSAttributedString.Key("nn.quoteBlock")
    static let highlightSpan = NSAttributedString.Key("nn.highlight")
    /// Range of the `[ ]` payload, so a click can flip it.
    static let checkboxToggle = NSAttributedString.Key("nn.checkboxToggle")
    /// UUID string of an embedded drawing.
    static let drawingRef = NSAttributedString.Key("nn.drawingRef")
}

/// Ornaments the text view paints for a line. Kept as a class so it can ride
/// along inside an attributed string.
final class LineDecoration: NSObject {
    enum Kind {
        case bullet(level: Int)
        case checkbox(checked: Bool, toggleRange: NSRange)
        case divider
        case drawing(id: UUID, size: CGSize)
    }

    let kind: Kind
    /// Horizontal position the ornament hangs off, in text-container space.
    let indent: CGFloat

    init(kind: Kind, indent: CGFloat) {
        self.kind = kind
        self.indent = indent
        super.init()
    }
}
