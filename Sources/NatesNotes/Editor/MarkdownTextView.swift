import AppKit

protocol MarkdownTextViewDelegate: AnyObject {
    func markdownTextViewDidEdit(_ view: MarkdownTextView)
    /// `rect` is the sketch card's frame in the window's top-left space, so the
    /// modal can grow out of exactly where the card sits.
    func markdownTextView(_ view: MarkdownTextView, didClickDrawing id: UUID, at rect: CGRect)
    func markdownTextViewRequestsNewDrawing(_ view: MarkdownTextView)
    func markdownTextView(_ view: MarkdownTextView, drawingFor id: UUID) -> Drawing?
}

/// Collapses `.hiddenMD` runs to nothing. Using null glyphs (rather than clear
/// text or zero-size fonts) keeps character offsets intact, so the buffer stays
/// honest markdown while the syntax disappears.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }

        var patched: [NSLayoutManager.GlyphProperty] = []
        patched.reserveCapacity(glyphRange.length)
        var changed = false

        for i in 0..<glyphRange.length {
            var property = props[i]
            let charIndex = charIndexes[i]
            if charIndex < storage.length,
               storage.attribute(.hiddenMD, at: charIndex, effectiveRange: nil) != nil {
                property.insert(.null)   // no image, no advancement
                changed = true
            }
            patched.append(property)
        }

        guard changed else { return 0 }   // 0 means "use the defaults"

        patched.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!,
                                    characterIndexes: charIndexes, font: aFont,
                                    forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }
}

final class MarkdownTextView: NSTextView {

    weak var mdDelegate: MarkdownTextViewDelegate?

    /// The text view the user is currently editing, so window-level commands
    /// (⇧⌘D, the Draw button) can reach the right document.
    private(set) static weak var focused: MarkdownTextView?
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private var slashMenu: SlashMenuController?
    private var slashTriggerLocation: Int?
    private var imageCache: [UUID: NSImage] = [:]
    private var restyleScheduled = false
    /// TextKit's ownership graph doesn't retain the storage for us.
    private var storageRef: NSTextStorage?

    // MARK: - Construction

    static func make() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.storageRef = storage
        view.configure()
        return view
    }

    private func configure() {
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = CGSize(width: 0, height: 28)
        insertionPointColor = Theme.accent
        font = Theme.body()
        linkTextAttributes = [
            .foregroundColor: Theme.accent,
            .cursor: NSCursor.pointingHand
        ]
        selectedTextAttributes = [
            .backgroundColor: Theme.accent.withAlphaComponent(0.22)
        ]
        typingAttributes = [
            .font: Theme.body(),
            .foregroundColor: Theme.textPrimary
        ]
    }

    // MARK: - Styling passes

    func restyle() {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let ns = storage.string as NSString
        var active: [NSRange] = []
        if selection.location <= ns.length {
            active.append(ns.paragraphRange(for: NSRange(location: selection.location, length: 0)))
            if selection.length > 0, selection.upperBound <= ns.length {
                active.append(ns.paragraphRange(for: selection))
            }
        }

        let context = MarkdownStyler.Context(
            activeParagraphs: active,
            isDark: isDark,
            drawingSize: { [weak self] id in self?.imageSize(for: id) }
        )
        MarkdownStyler.style(storage, context: context)
        needsDisplay = true
    }

    /// Restyles on the next runloop turn so several rapid edits collapse into one pass.
    func scheduleRestyle() {
        guard !restyleScheduled else { return }
        restyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.restyleScheduled = false
            self?.restyle()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        let previous = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let new = selectedRange()
        guard previous.location <= ns.length, new.location <= ns.length else { return }
        // Only re-run when the caret crosses into a different paragraph — that is
        // the only thing that changes which markers are revealed.
        let before = ns.paragraphRange(for: NSRange(location: min(previous.location, ns.length), length: 0))
        let after = ns.paragraphRange(for: NSRange(location: min(new.location, ns.length), length: 0))
        if before != after || previous.length != new.length {
            scheduleRestyle()
        }
    }

    // MARK: - Drawing embeds

    func invalidateImageCache(for id: UUID? = nil) {
        if let id { imageCache.removeValue(forKey: id) } else { imageCache.removeAll() }
        restyle()
    }

    private func imageSize(for id: UUID) -> CGSize? {
        image(for: id)?.size
    }

    private func image(for id: UUID) -> NSImage? {
        if let cached = imageCache[id] { return cached }
        guard let drawing = mdDelegate?.markdownTextView(self, drawingFor: id) else { return nil }
        let width = max(200, min(bounds.width - 8, Theme.editorMaxWidth))
        guard let img = ElementPainter.image(for: drawing,
                                             maxSize: CGSize(width: width, height: 460),
                                             isDark: isDark) else {
            // Empty drawing: reserve a placeholder band.
            let placeholder = NSImage(size: CGSize(width: width, height: 120))
            imageCache[id] = placeholder
            return placeholder
        }
        imageCache[id] = img
        return img
    }

    // MARK: - Ornaments

    /// Ornaments paint underneath the glyphs, so they go in before `super.draw`.
    override func draw(_ dirtyRect: NSRect) {
        drawOrnaments()
        super.draw(dirtyRect)
    }

    /// Hidden markers are zero-width glyphs, and a run of them at the start of a
    /// line gets absorbed into the *previous* line fragment. So ornaments anchor
    /// to the first character that actually draws — falling back to the trailing
    /// newline for lines that are hidden end to end (dividers, drawing embeds).
    private func anchorIndex(in range: NSRange, storage: NSTextStorage) -> Int {
        var i = range.location
        while i < range.upperBound && i < storage.length {
            if storage.attribute(.hiddenMD, at: i, effectiveRange: nil) == nil { return i }
            i += 1
        }
        return max(range.location, min(range.upperBound - 1, storage.length - 1))
    }

    private func fragmentRect(atChar index: Int, lm: NSLayoutManager) -> CGRect {
        guard lm.numberOfGlyphs > 0, index >= 0 else { return .zero }
        let glyph = min(lm.glyphIndexForCharacter(at: index), lm.numberOfGlyphs - 1)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Vertical extent of a whole block (code slab, multi-line quote).
    private func blockRect(for range: NSRange, storage: NSTextStorage,
                           lm: NSLayoutManager) -> CGRect {
        let head = fragmentRect(atChar: anchorIndex(in: range, storage: storage), lm: lm)
        let tailIndex = max(range.location, min(range.upperBound - 1, storage.length - 1))
        let tail = fragmentRect(atChar: tailIndex, lm: lm)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head.union(tail)
    }

    private func drawOrnaments() {
        guard let storage = textStorage, let lm = layoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let full = NSRange(location: 0, length: storage.length)

        // Code block slabs, behind everything else.
        storage.enumerateAttribute(.codeBlock, in: full) { value, range, _ in
            guard value != nil else { return }
            var box = self.blockRect(for: range, storage: storage, lm: lm)
            guard !box.isEmpty else { return }
            box.origin.x = origin.x
            box.origin.y += origin.y
            box.size.width = container.size.width - 2
            Theme.codeBG.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }

        // Quote bars.
        storage.enumerateAttribute(.quoteBlock, in: full) { value, range, _ in
            guard let indent = value as? CGFloat else { return }
            var box = self.blockRect(for: range, storage: storage, lm: lm)
            guard !box.isEmpty else { return }
            box.origin.y += origin.y
            let bar = CGRect(x: origin.x + indent + 1, y: box.minY + 1,
                             width: 3, height: max(box.height - 2, 4))
            Theme.quoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Inline code chips.
        storage.enumerateAttribute(.inlineCode, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { chipRect, _ in
                var r = chipRect
                r.origin.x += origin.x - 3
                r.origin.y += origin.y + 1
                r.size.width += 6
                r.size.height -= 2
                Theme.codeBG.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
        }

        // Highlight spans.
        storage.enumerateAttribute(.highlightSpan, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { chipRect, _ in
                var r = chipRect
                r.origin.x += origin.x - 2
                r.origin.y += origin.y + 2
                r.size.width += 4
                r.size.height -= 4
                Theme.highlightBG.setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            }
        }

        // Line ornaments: bullets, checkboxes, rules, embedded drawings.
        storage.enumerateAttribute(.lineDecoration, in: full) { value, range, _ in
            guard let deco = value as? LineDecoration else { return }
            let anchor = self.anchorIndex(in: range, storage: storage)
            var line = self.fragmentRect(atChar: anchor, lm: lm)
            guard !line.isEmpty else { return }
            line.origin.x += origin.x
            line.origin.y += origin.y

            // Centre ornaments on the cap height of the line's own text, not on
            // the line box — line-height multipliers make those disagree.
            let glyph = min(lm.glyphIndexForCharacter(at: anchor), max(lm.numberOfGlyphs - 1, 0))
            let baseline = line.minY + lm.location(forGlyphAt: glyph).y
            let anchorFont = storage.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont
                ?? Theme.body()
            let centerY = baseline - anchorFont.capHeight / 2

            switch deco.kind {
            case .bullet(let level):
                let x = origin.x + deco.indent + 8
                let y = centerY
                let size: CGFloat = level == 0 ? 5.5 : 5
                let dot = CGRect(x: x, y: y - size / 2, width: size, height: size)
                Theme.textSecondary.setFill()
                if level % 3 == 1 {
                    NSBezierPath(ovalIn: dot).stroke()
                    Theme.textSecondary.setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                    ring.lineWidth = 1.2
                    ring.stroke()
                } else {
                    NSBezierPath(ovalIn: dot).fill()
                }

            case .checkbox(let checked, _):
                let box = CGRect(x: origin.x + deco.indent + 4,
                                 y: centerY - 8, width: 16, height: 16)
                let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                if checked {
                    Theme.checkDone.setFill()
                    path.fill()
                    let tick = NSBezierPath()
                    tick.move(to: CGPoint(x: box.minX + 4, y: box.midY + 0.5))
                    tick.line(to: CGPoint(x: box.midX - 0.5, y: box.maxY - 4.5))
                    tick.line(to: CGPoint(x: box.maxX - 3.5, y: box.minY + 4.5))
                    tick.lineWidth = 2
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    tick.stroke()
                } else {
                    Theme.textTertiary.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }

            case .divider:
                let y = (line.midY).rounded()
                let rule = CGRect(x: origin.x, y: y, width: container.size.width - 4, height: 1)
                Theme.hairline.setFill()
                rule.fill()

            case .drawing(let id, _):
                guard let image = self.image(for: id) else { return }
                let maxWidth = container.size.width - 4
                let scale = min(1, maxWidth / max(image.size.width, 1))
                let w = image.size.width * scale
                let h = image.size.height * scale
                let frame = CGRect(x: origin.x + (maxWidth - w) / 2,
                                   y: line.minY + 8, width: w, height: h)
                let card = frame.insetBy(dx: -10, dy: -8)
                Theme.raisedBG.setFill()
                NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11).fill()
                // A faint accent edge marks the card as a live, openable object.
                Theme.accent.withAlphaComponent(0.28).setStroke()
                let border = NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11)
                border.lineWidth = 1
                border.stroke()
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
        }
    }

    // MARK: - Mouse

    override func becomeFirstResponder() -> Bool {
        MarkdownTextView.focused = self
        return super.becomeFirstResponder()
    }

    /// The drawn card rectangle for an embedded sketch, in this view's space.
    func cardRect(for id: UUID) -> CGRect? {
        guard let storage = textStorage, let lm = layoutManager,
              let container = textContainer else { return nil }
        let origin = textContainerOrigin
        var found: CGRect?
        storage.enumerateAttribute(.lineDecoration,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let deco = value as? LineDecoration,
                  case .drawing(let drawingID, _) = deco.kind, drawingID == id,
                  let image = self.image(for: id) else { return }
            var line = self.fragmentRect(atChar: self.anchorIndex(in: range, storage: storage), lm: lm)
            guard !line.isEmpty else { return }
            line.origin.x += origin.x
            line.origin.y += origin.y
            let maxWidth = container.size.width - 4
            let scale = min(1, maxWidth / max(image.size.width, 1))
            let w = image.size.width * scale, h = image.size.height * scale
            let frame = CGRect(x: origin.x + (maxWidth - w) / 2, y: line.minY + 8,
                               width: w, height: h)
            found = frame.insetBy(dx: -10, dy: -8)
            stop.pointee = true
        }
        return found
    }

    /// Same rectangle, converted into the window's top-left coordinate space,
    /// which is what SwiftUI overlays use.
    func cardRectInWindow(for id: UUID) -> CGRect? {
        guard let rect = cardRect(for: id), let window else { return nil }
        let inWindow = convert(rect, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY,
                      width: inWindow.width, height: inWindow.height)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = decorationHit(at: point) {
            switch hit.kind {
            case .checkbox(_, let toggleRange):
                toggleCheckbox(at: toggleRange)
                return
            case .drawing(let id, _):
                mdDelegate?.markdownTextView(self, didClickDrawing: id,
                                             at: cardRectInWindow(for: id) ?? .zero)
                return
            default:
                break
            }
        }
        dismissSlashMenu()
        super.mouseDown(with: event)
    }

    private func decorationHit(at point: CGPoint) -> LineDecoration? {
        guard let storage = textStorage, let lm = layoutManager,
              let container = textContainer else { return nil }
        let origin = textContainerOrigin
        var found: LineDecoration?
        storage.enumerateAttribute(.lineDecoration,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let deco = value as? LineDecoration else { return }
            var line = self.fragmentRect(atChar: self.anchorIndex(in: range, storage: storage), lm: lm)
            guard !line.isEmpty else { return }
            line.origin.x += origin.x
            line.origin.y += origin.y
            switch deco.kind {
            case .checkbox:
                let box = CGRect(x: origin.x + deco.indent + 4, y: line.midY - 10,
                                 width: 20, height: 20)
                if box.contains(point) { found = deco; stop.pointee = true }
            case .drawing:
                if line.contains(point) { found = deco; stop.pointee = true }
            default:
                break
            }
        }
        return found
    }

    private func toggleCheckbox(at range: NSRange) {
        guard let storage = textStorage, range.upperBound <= storage.length else { return }
        let current = (storage.string as NSString).substring(with: range)
        let replacement = current.lowercased() == "x" ? " " : "x"
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        restyle()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if let menu = slashMenu, menu.isVisible {
            switch event.keyCode {
            case 125: menu.moveSelection(by: 1); return       // down
            case 126: menu.moveSelection(by: -1); return      // up
            case 36, 76: menu.commitSelection(); return       // return
            case 53: dismissSlashMenu(); return               // escape
            case 48: menu.commitSelection(); return           // tab
            default: break
            }
        }

        if event.keyCode == 48 {                              // tab
            if handleTab(shift: event.modifierFlags.contains(.shift)) { return }
        }
        if event.keyCode == 36 {                              // return
            if handleReturn() { return }
        }
        super.keyDown(with: event)

        if let menu = slashMenu, menu.isVisible { updateSlashFilter() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if let s = string as? String, s == "/" {
            maybeShowSlashMenu()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        restyle()
        mdDelegate?.markdownTextViewDidEdit(self)
    }

    /// Continues lists on Return, and clears an empty marker instead of extending it.
    private func handleReturn() -> Bool {
        guard let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let caret = selectedRange()
        guard caret.length == 0, caret.location <= ns.length else { return false }
        let paragraph = ns.paragraphRange(for: NSRange(location: caret.location, length: 0))
        let line = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)

        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)

        var marker: String?
        var markerLength = 0
        if MarkdownStyler.checkboxState(String(body)) != nil {
            marker = "- [ ] "
            markerLength = 6
        } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            marker = String(body.prefix(2))
            markerLength = 2
        } else if let len = MarkdownStyler.orderedMarkerLength(String(body)) {
            let digits = String(body.prefix(len - 2))
            let next = (Int(digits) ?? 1) + 1
            marker = "\(next). "
            markerLength = len
        } else if body.hasPrefix("> ") {
            marker = "> "
            markerLength = 2
        }

        guard let marker else { return false }

        // Empty item: outdent one level, or drop the marker entirely.
        if body.count == markerLength {
            let removeRange = NSRange(location: paragraph.location,
                                      length: leading.count + markerLength)
            if shouldChangeText(in: removeRange, replacementString: "") {
                storage.replaceCharacters(in: removeRange, with: "")
                didChangeText()
            }
            return true
        }

        let insertion = "\n" + leading + marker
        if shouldChangeText(in: caret, replacementString: insertion) {
            storage.replaceCharacters(in: caret, with: insertion)
            setSelectedRange(NSRange(location: caret.location + (insertion as NSString).length, length: 0))
            didChangeText()
        }
        return true
    }

    /// Tab indents the current list item rather than inserting a tab character.
    private func handleTab(shift: Bool) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let caret = selectedRange()
        guard caret.location <= ns.length else { return false }
        let paragraph = ns.paragraphRange(for: caret)
        let line = ns.substring(with: paragraph)
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)

        let isListItem = body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ")
            || MarkdownStyler.orderedMarkerLength(String(body)) != nil
        guard isListItem else { return false }

        if shift {
            guard leading.count >= 2 else { return true }
            let removeRange = NSRange(location: paragraph.location, length: 2)
            if shouldChangeText(in: removeRange, replacementString: "") {
                storage.replaceCharacters(in: removeRange, with: "")
                didChangeText()
            }
        } else {
            let insertRange = NSRange(location: paragraph.location, length: 0)
            if shouldChangeText(in: insertRange, replacementString: "  ") {
                storage.replaceCharacters(in: insertRange, with: "  ")
                setSelectedRange(NSRange(location: caret.location + 2, length: 0))
                didChangeText()
            }
        }
        return true
    }

    // MARK: - Inline formatting commands

    func toggleWrap(_ delimiter: String) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let range = selectedRange()
        let d = delimiter as NSString

        // Already wrapped? Unwrap.
        let outer = NSRange(location: range.location - d.length,
                            length: range.length + d.length * 2)
        if outer.location >= 0, outer.upperBound <= ns.length {
            let candidate = ns.substring(with: outer)
            if candidate.hasPrefix(delimiter) && candidate.hasSuffix(delimiter) {
                let inner = ns.substring(with: range)
                if shouldChangeText(in: outer, replacementString: inner) {
                    storage.replaceCharacters(in: outer, with: inner)
                    setSelectedRange(NSRange(location: outer.location, length: (inner as NSString).length))
                    didChangeText()
                }
                return
            }
        }

        let selected = range.length > 0 ? ns.substring(with: range) : ""
        let replacement = delimiter + selected + delimiter
        if shouldChangeText(in: range, replacementString: replacement) {
            storage.replaceCharacters(in: range, with: replacement)
            let caret = range.location + d.length
            setSelectedRange(NSRange(location: caret, length: (selected as NSString).length))
            didChangeText()
        }
    }

    /// Replaces the current line's block marker with `prefix` (empty clears it).
    func applyBlockPrefix(_ prefix: String) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let caret = selectedRange()
        let paragraph = ns.paragraphRange(for: NSRange(location: caret.location, length: 0))
        var line = ns.substring(with: paragraph)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }

        let stripped = stripBlockMarker(line)
        let newLine = prefix + stripped + (hadNewline ? "\n" : "")
        if shouldChangeText(in: paragraph, replacementString: newLine) {
            storage.replaceCharacters(in: paragraph, with: newLine)
            let delta = (newLine as NSString).length - paragraph.length
            setSelectedRange(NSRange(location: max(paragraph.location,
                                                   min(caret.location + delta, storage.length)),
                                     length: 0))
            didChangeText()
        }
    }

    private func stripBlockMarker(_ line: String) -> String {
        var s = line
        if let (_, markerLength) = MarkdownStyler.headingLevel(s) {
            s = String(s.dropFirst(markerLength))
        } else if MarkdownStyler.checkboxState(s) != nil {
            s = String(s.dropFirst(min(6, s.count)))
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") || s.hasPrefix("> ") {
            s = String(s.dropFirst(2))
        } else if let len = MarkdownStyler.orderedMarkerLength(s) {
            s = String(s.dropFirst(len))
        }
        return s
    }

    func insertBlock(_ text: String) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: text) {
            storage.replaceCharacters(in: range, with: text)
            setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
            didChangeText()
        }
    }

    // MARK: - Responder-chain commands (wired to the app menu)

    @objc func toggleBoldMD(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalicMD(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleCodeMD(_ sender: Any?) { toggleWrap("`") }
    @objc func toggleStrikeMD(_ sender: Any?) { toggleWrap("~~") }
    @objc func toggleHighlightMD(_ sender: Any?) { toggleWrap("==") }
    @objc func insertDrawingMD(_ sender: Any?) {
        mdDelegate?.markdownTextViewRequestsNewDrawing(self)
    }
    @objc func makeHeading1(_ sender: Any?) { applyBlockPrefix("# ") }
    @objc func makeHeading2(_ sender: Any?) { applyBlockPrefix("## ") }
    @objc func makeHeading3(_ sender: Any?) { applyBlockPrefix("### ") }
    @objc func makeBody(_ sender: Any?) { applyBlockPrefix("") }
    @objc func makeBulletList(_ sender: Any?) { applyBlockPrefix("- ") }
    @objc func makeTodo(_ sender: Any?) { applyBlockPrefix("- [ ] ") }
    @objc func makeQuote(_ sender: Any?) { applyBlockPrefix("> ") }

    // MARK: - Slash menu

    private func maybeShowSlashMenu() {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let caret = selectedRange().location
        // Only trigger at the start of a line or after whitespace.
        let precedingIndex = caret - 2
        if precedingIndex >= 0 {
            let ch = ns.substring(with: NSRange(location: precedingIndex, length: 1))
            guard ch == " " || ch == "\n" || ch == "\t" else { return }
        }
        slashTriggerLocation = caret - 1

        let controller = SlashMenuController { [weak self] command in
            self?.applySlashCommand(command)
        } onDismiss: { [weak self] in
            self?.slashMenu = nil
            self?.slashTriggerLocation = nil
        }
        slashMenu = controller
        controller.show(relativeTo: caretScreenRect(), parent: window)
    }

    private func updateSlashFilter() {
        guard let menu = slashMenu, let start = slashTriggerLocation,
              let storage = textStorage else { return }
        let caret = selectedRange().location
        guard caret > start, caret <= storage.length else {
            dismissSlashMenu()
            return
        }
        let query = (storage.string as NSString)
            .substring(with: NSRange(location: start + 1, length: caret - start - 1))
        if query.contains(" ") || query.count > 20 {
            dismissSlashMenu()
            return
        }
        menu.filter(query)
    }

    private func dismissSlashMenu() {
        slashMenu?.close()
        slashMenu = nil
        slashTriggerLocation = nil
    }

    private func applySlashCommand(_ command: SlashCommand) {
        guard let storage = textStorage, let start = slashTriggerLocation else { return }
        let caret = selectedRange().location
        let removeRange = NSRange(location: start, length: max(0, min(caret, storage.length) - start))
        if shouldChangeText(in: removeRange, replacementString: "") {
            storage.replaceCharacters(in: removeRange, with: "")
            setSelectedRange(NSRange(location: start, length: 0))
            didChangeText()
        }
        dismissSlashMenu()

        switch command.action {
        case .blockPrefix(let prefix):
            applyBlockPrefix(prefix)
        case .insert(let text, let caretOffset):
            let location = selectedRange().location
            insertBlock(text)
            setSelectedRange(NSRange(location: min(location + caretOffset, storage.length), length: 0))
        case .newDrawing:
            mdDelegate?.markdownTextViewRequestsNewDrawing(self)
        }
        restyle()
    }

    private func caretScreenRect() -> NSRect {
        guard let lm = layoutManager, let container = textContainer, let window else { return .zero }
        let caret = selectedRange()
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: max(0, caret.location - 1), length: 1),
                                   actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        let inWindow = convert(rect, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: - Layout

    private var lastColumnWidth: CGFloat = 0

    /// Keeps the text in a centred reading column no wider than `editorMaxWidth`.
    override func layout() {
        super.layout()
        let available = enclosingScrollView?.contentSize.width ?? bounds.width
        guard available > 40 else { return }
        let column = min(Theme.editorMaxWidth, max(260, available - Theme.editorHPadding * 2))
        let inset = max(20, (available - column) / 2)
        if abs(textContainerInset.width - inset) > 0.5 {
            textContainerInset = CGSize(width: inset, height: 40)
        }
        if abs(lastColumnWidth - column) > 6 {
            lastColumnWidth = column
            imageCache.removeAll()          // embedded drawings re-fit to the new width
            scheduleRestyle()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let container = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height) + textContainerInset.height * 2)
    }
}
