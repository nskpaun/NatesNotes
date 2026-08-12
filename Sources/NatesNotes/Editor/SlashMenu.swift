import AppKit

struct SlashCommand {
    enum Action {
        /// Replace the line's block marker with this prefix.
        case blockPrefix(String)
        /// Insert literal text; the Int is where the caret lands afterwards.
        case insert(String, Int)
        case newDrawing
    }

    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let action: Action

    static let all: [SlashCommand] = [
        .init(title: "Text", subtitle: "Plain paragraph", symbol: "text.alignleft",
              keywords: ["text", "paragraph", "body"], action: .blockPrefix("")),
        .init(title: "Heading 1", subtitle: "Big section title", symbol: "textformat.size.larger",
              keywords: ["h1", "title", "heading"], action: .blockPrefix("# ")),
        .init(title: "Heading 2", subtitle: "Medium section title", symbol: "textformat.size",
              keywords: ["h2", "heading", "subtitle"], action: .blockPrefix("## ")),
        .init(title: "Heading 3", subtitle: "Small section title", symbol: "textformat.size.smaller",
              keywords: ["h3", "heading"], action: .blockPrefix("### ")),
        .init(title: "Bulleted list", subtitle: "A simple bullet", symbol: "list.bullet",
              keywords: ["bullet", "list", "ul"], action: .blockPrefix("- ")),
        .init(title: "Numbered list", subtitle: "An ordered list", symbol: "list.number",
              keywords: ["number", "ordered", "ol"], action: .blockPrefix("1. ")),
        .init(title: "To-do", subtitle: "Track a task with a checkbox", symbol: "checklist",
              keywords: ["todo", "task", "check", "checkbox"], action: .blockPrefix("- [ ] ")),
        .init(title: "Quote", subtitle: "Capture a quotation", symbol: "quote.opening",
              keywords: ["quote", "blockquote"], action: .blockPrefix("> ")),
        .init(title: "Divider", subtitle: "Visually split sections", symbol: "minus",
              keywords: ["divider", "rule", "hr", "line"], action: .insert("---\n", 4)),
        .init(title: "Code block", subtitle: "Monospaced code with syntax fence", symbol: "chevron.left.forwardslash.chevron.right",
              keywords: ["code", "snippet", "fence"], action: .insert("```\n\n```\n", 4)),
        .init(title: "Drawing", subtitle: "Sketch a diagram right here", symbol: "scribble.variable",
              keywords: ["draw", "diagram", "sketch", "excalidraw", "canvas"], action: .newDrawing),
        .init(title: "Table row", subtitle: "Start a markdown table", symbol: "tablecells",
              keywords: ["table", "grid"],
              action: .insert("| Column | Column |\n| --- | --- |\n|  |  |\n", 2)),
        .init(title: "Highlight", subtitle: "Mark text with a highlighter", symbol: "highlighter",
              keywords: ["highlight", "mark"], action: .insert("====", 2)),
        .init(title: "Link", subtitle: "Insert a hyperlink", symbol: "link",
              keywords: ["link", "url", "href"], action: .insert("[](https://)", 1))
    ]

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q) || keywords.contains { $0.hasPrefix(q) }
    }
}

/// A floating panel of block types, driven entirely from the text view's key
/// handling so typing keeps flowing into the document while it's open.
final class SlashMenuController: NSObject {

    private let panel: NSPanel
    private let listView: SlashListView
    private let onCommit: (SlashCommand) -> Void
    private let onDismiss: () -> Void

    private var results: [SlashCommand] = SlashCommand.all
    private var selectedIndex = 0

    var isVisible: Bool { panel.isVisible }

    init(onCommit: @escaping (SlashCommand) -> Void, onDismiss: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onDismiss = onDismiss

        listView = SlashListView()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = listView
        panel.hidesOnDeactivate = true

        super.init()
        listView.onPick = { [weak self] index in
            guard let self, self.results.indices.contains(index) else { return }
            self.onCommit(self.results[index])
        }
        refresh()
    }

    func show(relativeTo caretRect: NSRect, parent: NSWindow?) {
        let height = min(320, CGFloat(max(results.count, 1)) * 44 + 16)
        var frame = NSRect(x: caretRect.minX, y: caretRect.minY - height - 6,
                           width: 300, height: height)
        if let screen = parent?.screen ?? NSScreen.main {
            // Flip above the caret when there isn't room below.
            if frame.minY < screen.visibleFrame.minY + 20 {
                frame.origin.y = caretRect.maxY + 6
            }
            frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.width - 12)
            frame.origin.x = max(frame.origin.x, screen.visibleFrame.minX + 12)
        }
        panel.setFrame(frame, display: true)
        parent?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    func filter(_ query: String) {
        results = SlashCommand.all.filter { $0.matches(query) }
        selectedIndex = 0
        if results.isEmpty {
            close()
            return
        }
        refresh()
        let height = min(320, CGFloat(results.count) * 44 + 16)
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
        refresh()
    }

    func commitSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        onCommit(results[selectedIndex])
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onDismiss()
    }

    private func refresh() {
        listView.items = results
        listView.selectedIndex = selectedIndex
        listView.needsDisplay = true
    }
}

/// Hand-drawn list — simpler and lighter than an NSTableView for 14 static rows.
final class SlashListView: NSView {

    var items: [SlashCommand] = []
    var selectedIndex = 0
    var onPick: ((Int) -> Void)?

    private let rowHeight: CGFloat = 44
    private let inset: CGFloat = 8

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Card
        let card = bounds
        Theme.raisedBG.setFill()
        let bg = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        bg.fill()
        Theme.hairline.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        for (i, item) in items.enumerated() {
            let row = rowRect(i)
            guard row.intersects(dirtyRect) else { continue }

            if i == selectedIndex {
                Theme.accent.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 4, dy: 2), xRadius: 7, yRadius: 7).fill()
            }

            // Icon tile
            let tile = CGRect(x: row.minX + 12, y: row.midY - 13, width: 26, height: 26)
            Theme.hoverBG.setFill()
            NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
            if let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                let tinted = symbol.withSymbolConfiguration(config)
                tinted?.isTemplate = true
                let iconRect = CGRect(x: tile.midX - 7, y: tile.midY - 7, width: 14, height: 14)
                Theme.textSecondary.set()
                tinted?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: true, hints: nil)
            }

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: Theme.textPrimary
            ]
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: Theme.textTertiary
            ]
            NSString(string: item.title).draw(at: CGPoint(x: tile.maxX + 10, y: row.minY + 8),
                                              withAttributes: titleAttrs)
            NSString(string: item.subtitle).draw(at: CGPoint(x: tile.maxX + 10, y: row.minY + 24),
                                                 withAttributes: subtitleAttrs)
        }
    }

    private func rowRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: inset + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in items.indices where rowRect(i).contains(p) {
            onPick?(i)
            return
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in items.indices where rowRect(i).contains(p) {
            if selectedIndex != i { selectedIndex = i; needsDisplay = true }
            return
        }
    }
}
