import UIKit

protocol MarkdownEditorDelegate: AnyObject {
    func markdownEditorDidEdit(_ view: MarkdownEditorTextView)
    func markdownEditor(_ view: MarkdownEditorTextView, drawingFor id: UUID) -> Drawing?
    func markdownEditor(_ view: MarkdownEditorTextView, didTapDrawing id: UUID)
}

/// The iPhone editor.
///
/// Same engine as the Mac: the buffer holds plain markdown, `MarkdownStyler`
/// decides the attributes, and `MarkdownLayoutManager` nulls the syntax glyphs
/// so they occupy no width without changing a single character offset.
///
/// The one iOS-specific requirement is construction. `UITextView()` opts into
/// TextKit 2, which has no glyph generation to intercept, so the whole
/// live-preview mechanism silently stops working. Handing it a text container
/// keeps it on TextKit 1.
final class MarkdownEditorTextView: UITextView {

    weak var mdDelegate: MarkdownEditorDelegate?

    private var imageCache: [UUID: UIImage] = [:]
    private var restyleScheduled = false

    var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    // MARK: - Construction

    init() {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        super.init(frame: .zero, textContainer: container)

        backgroundColor = .clear
        isEditable = true
        isScrollEnabled = true
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 16, left: 18, bottom: 320, right: 18)
        autocorrectionType = .yes
        smartDashesType = .no          // markdown needs literal --- and --
        smartQuotesType = .no
        tintColor = Theme.accent
        delegate = self

        addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                    action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    /// Replaces the buffer without letting the change echo back as a user edit.
    /// The caret follows the content it sat next to, so a sync pull landing in
    /// an open editor doesn't teleport it.
    func setMarkdown(_ text: String) {
        guard textStorage.string != text else { return }
        let caret = TextSync.remappedCaret(selectedRange, from: textStorage.string, to: text)
        textStorage.setAttributedString(NSAttributedString(string: text))
        selectedRange = caret
        imageCache.removeAll()
        restyle()
    }

    var markdown: String { textStorage.string }

    // MARK: - Styling

    func restyle() {
        let ns = textStorage.string as NSString
        var active: [NSRange] = []
        if selectedRange.location <= ns.length {
            active.append(ns.paragraphRange(for: NSRange(location: selectedRange.location,
                                                         length: 0)))
            if selectedRange.length > 0, selectedRange.upperBound <= ns.length {
                active.append(ns.paragraphRange(for: selectedRange))
            }
        }

        let context = MarkdownStyler.Context(
            activeParagraphs: active,
            isDark: isDark,
            drawingSize: { [weak self] id in self?.imageSize(for: id) }
        )
        MarkdownStyler.style(textStorage, context: context)
        setNeedsDisplay()
    }

    func scheduleRestyle() {
        guard !restyleScheduled else { return }
        restyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.restyleScheduled = false
            self?.restyle()
        }
    }

    // MARK: - Embedded drawings

    private func image(for id: UUID) -> UIImage? {
        if let cached = imageCache[id] { return cached }
        guard let drawing = mdDelegate?.markdownEditor(self, drawingFor: id) else { return nil }
        let width = max(120, bounds.width - textContainerInset.left - textContainerInset.right - 8)
        guard let image = ElementPainter.image(for: drawing,
                                               maxSize: CGSize(width: width, height: 420),
                                               isDark: isDark) else { return nil }
        imageCache[id] = image
        return image
    }

    private func imageSize(for id: UUID) -> CGSize? {
        image(for: id).map { CGSize(width: $0.size.width, height: $0.size.height + 14) }
    }

    func invalidateDrawings() {
        imageCache.removeAll()
        restyle()
    }

    // MARK: - Ornaments

    override func draw(_ rect: CGRect) {
        drawBlockOrnaments()
        super.draw(rect)        // the text itself
        drawLineOrnaments()
    }

    /// Where the text container actually starts. The line-fragment padding is
    /// part of it — AppKit folds that into `textContainerOrigin`, UIKit doesn't.
    private var containerOrigin: CGPoint {
        CGPoint(x: textContainerInset.left + textContainer.lineFragmentPadding,
                y: textContainerInset.top)
    }

    /// Backgrounds — they must sit behind the glyphs, so they are drawn first.
    private func drawBlockOrnaments() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let lm = layoutManager
        let storage = textStorage
        let origin = containerOrigin
        let full = NSRange(location: 0, length: storage.length)

        storage.enumerateAttribute(.codeBlock, in: full) { value, range, _ in
            guard value != nil else { return }
            var box = self.blockRect(for: range)
            guard !box.isEmpty else { return }
            box.origin.x = origin.x
            box.origin.y += origin.y
            box.size.width = self.textContainer.size.width - 2
            ctx.setFillColor(Theme.codeBG.cgColor)
            UIBezierPath(roundedRect: box, cornerRadius: 6).fill()
        }

        storage.enumerateAttribute(.quoteBlock, in: full) { value, range, _ in
            guard let indent = value as? CGFloat else { return }
            var box = self.blockRect(for: range)
            guard !box.isEmpty else { return }
            box.origin.y += origin.y
            let bar = CGRect(x: origin.x + indent + 1, y: box.minY + 1,
                             width: 3, height: max(box.height - 2, 4))
            ctx.setFillColor(Theme.quoteBar.cgColor)
            UIBezierPath(roundedRect: bar, cornerRadius: 1.5).fill()
        }

        for (attribute, colour, inset, radius) in [
            (NSAttributedString.Key.inlineCode, Theme.codeBG, CGPoint(x: -3, y: 1), CGFloat(4)),
            (NSAttributedString.Key.highlightSpan, Theme.highlightBG, CGPoint(x: -2, y: 2), CGFloat(3))
        ] {
            storage.enumerateAttribute(attribute, in: full) { value, range, _ in
                guard value != nil else { return }
                let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                lm.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: self.textContainer
                ) { chip, _ in
                    var r = chip
                    r.origin.x += origin.x + inset.x
                    r.origin.y += origin.y + inset.y
                    r.size.width -= inset.x * 2
                    r.size.height -= inset.y * 2
                    ctx.setFillColor(colour.cgColor)
                    UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
                }
            }
        }
    }

    /// Bullets, checkboxes, rules and sketch cards, drawn over the text.
    private func drawLineOrnaments() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let storage = textStorage
        let origin = containerOrigin
        let full = NSRange(location: 0, length: storage.length)

        let lm = layoutManager
        let container = textContainer

        storage.enumerateAttribute(.lineDecoration, in: full) { value, range, _ in
            guard let deco = value as? LineDecoration else { return }
            let anchor = self.anchorIndex(in: range)
            var line = self.fragmentRect(atChar: anchor)
            guard !line.isEmpty else { return }
            line.origin.x += origin.x
            line.origin.y += origin.y

            // Centre ornaments on the cap height of the line's own text, not on
            // the line box — line-height multipliers make those disagree.
            let glyph = min(lm.glyphIndexForCharacter(at: anchor), max(lm.numberOfGlyphs - 1, 0))
            let baseline = line.minY + lm.location(forGlyphAt: glyph).y
            let anchorFont = storage.attribute(.font, at: anchor,
                                               effectiveRange: nil) as? UIFont ?? Theme.body()
            let centerY = baseline - anchorFont.capHeight / 2

            switch deco.kind {
            case .bullet(let level):
                let size: CGFloat = level == 0 ? 5.5 : 5
                let dot = CGRect(x: origin.x + deco.indent + 8,
                                 y: centerY - size / 2, width: size, height: size)
                if level % 3 == 1 {
                    ctx.setStrokeColor(Theme.textSecondary.cgColor)
                    let ring = UIBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                    ring.lineWidth = 1.2
                    ring.stroke()
                } else {
                    ctx.setFillColor(Theme.textSecondary.cgColor)
                    UIBezierPath(ovalIn: dot).fill()
                }

            case .checkbox(let checked, _):
                let box = CGRect(x: origin.x + deco.indent + 4,
                                 y: centerY - 8, width: 16, height: 16)
                let path = UIBezierPath(roundedRect: box, cornerRadius: 4)
                if checked {
                    ctx.setFillColor(Theme.checkDone.cgColor)
                    path.fill()
                    let tick = UIBezierPath()
                    tick.move(to: CGPoint(x: box.minX + 4, y: box.midY + 0.5))
                    tick.addLine(to: CGPoint(x: box.midX - 0.5, y: box.maxY - 4.5))
                    tick.addLine(to: CGPoint(x: box.maxX - 3.5, y: box.minY + 4.5))
                    tick.lineWidth = 2
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    UIColor.white.setStroke()
                    tick.stroke()
                } else {
                    ctx.setStrokeColor(Theme.textTertiary.cgColor)
                    path.lineWidth = 1.5
                    path.stroke()
                }

            case .divider:
                let y = line.midY.rounded()
                ctx.setFillColor(Theme.hairline.cgColor)
                ctx.fill(CGRect(x: origin.x, y: y, width: container.size.width - 4, height: 1))

            case .drawing(let id, _):
                guard let image = self.image(for: id) else { return }
                let maxWidth = container.size.width - 4
                let scale = min(1, maxWidth / max(image.size.width, 1))
                let frame = CGRect(x: origin.x + (maxWidth - image.size.width * scale) / 2,
                                   y: line.minY + 8,
                                   width: image.size.width * scale,
                                   height: image.size.height * scale)
                let card = frame.insetBy(dx: -10, dy: -8)
                ctx.setFillColor(Theme.raisedBG.cgColor)
                UIBezierPath(roundedRect: card, cornerRadius: 11).fill()
                // A faint accent edge marks the card as a live, openable object.
                ctx.setStrokeColor(Theme.accent.withAlphaComponent(0.28).cgColor)
                let border = UIBezierPath(roundedRect: card, cornerRadius: 11)
                border.lineWidth = 1
                border.stroke()
                image.draw(in: frame)
            }
        }
    }

    // MARK: - Geometry
    //
    // A run of zero-width glyphs at the start of a line is absorbed into the
    // *previous* fragment, so an ornament must hang off the line's first
    // visible character — or its trailing newline when the line is hidden end
    // to end, as dividers and drawing embeds are.

    private func anchorIndex(in range: NSRange) -> Int {
        let storage = textStorage
        for i in range.location..<min(range.upperBound, storage.length) {
            if storage.attribute(.hiddenMD, at: i, effectiveRange: nil) == nil { return i }
        }
        return max(range.location, min(range.upperBound - 1, storage.length - 1))
    }

    private func fragmentRect(atChar index: Int) -> CGRect {
        guard index >= 0, index < textStorage.length else { return .zero }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func blockRect(for range: NSRange) -> CGRect {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                              actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
    }

    // MARK: - Touch

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let inContainer = CGPoint(x: point.x - textContainerInset.left,
                                  y: point.y - textContainerInset.top)
        let index = layoutManager.characterIndex(for: inContainer, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < textStorage.length else { becomeFirstResponder(); return }

        let paragraph = (textStorage.string as NSString)
            .paragraphRange(for: NSRange(location: index, length: 0))

        // A sketch card opens rather than placing a caret.
        if let deco = textStorage.attribute(.lineDecoration, at: paragraph.location,
                                            effectiveRange: nil) as? LineDecoration,
           case .drawing(let id, _) = deco.kind {
            mdDelegate?.markdownEditor(self, didTapDrawing: id)
            return
        }

        // Tapping the box flips the to-do; tapping its text does not.
        if let deco = textStorage.attribute(.lineDecoration, at: paragraph.location,
                                            effectiveRange: nil) as? LineDecoration,
           case .checkbox(let checked, let toggleRange) = deco.kind {
            var line = fragmentRect(atChar: anchorIndex(in: paragraph))
            line.origin.y += textContainerInset.top
            let hit = CGRect(x: textContainerInset.left + deco.indent - 26,
                             y: line.midY - 14, width: 30, height: 28)
            if hit.contains(point) {
                let replacement = checked ? " " : "x"
                textStorage.replaceCharacters(in: toggleRange, with: replacement)
                restyle()
                mdDelegate?.markdownEditorDidEdit(self)
                return
            }
        }

        becomeFirstResponder()
    }
}

// MARK: - Editing

extension MarkdownEditorTextView: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        scheduleRestyle()
        mdDelegate?.markdownEditorDidEdit(self)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // The caret moving is what reveals and re-hides syntax markers.
        scheduleRestyle()
    }

    /// `Return` continues the list you're in, and ends it on an empty item.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        guard text == "\n" else { return true }

        let ns = textStorage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let line = ns.substring(with: paragraph)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(indent.count)

        func endList() {
            textStorage.replaceCharacters(in: paragraph, with: "\n")
            selectedRange = NSRange(location: paragraph.location + 1, length: 0)
            restyle()
            mdDelegate?.markdownEditorDidEdit(self)
        }

        if MarkdownStyler.checkboxState(String(body)) != nil {
            if body.count <= 6 { endList(); return false }
            insertContinuation("\n\(indent)- [ ] ", at: range)
            return false
        }
        if let length = MarkdownStyler.orderedMarkerLength(String(body)) {
            if body.count <= length { endList(); return false }
            let number = Int(body.prefix(length).filter(\.isNumber)) ?? 1
            insertContinuation("\n\(indent)\(number + 1). ", at: range)
            return false
        }
        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            if body.count <= 2 { endList(); return false }
            insertContinuation("\n\(indent)- ", at: range)
            return false
        }
        if body.hasPrefix("> ") {
            if body.count <= 2 { endList(); return false }
            insertContinuation("\n\(indent)> ", at: range)
            return false
        }
        return true
    }

    private func insertContinuation(_ string: String, at range: NSRange) {
        textStorage.replaceCharacters(in: range, with: string)
        selectedRange = NSRange(location: range.location + (string as NSString).length, length: 0)
        restyle()
        mdDelegate?.markdownEditorDidEdit(self)
    }
}
