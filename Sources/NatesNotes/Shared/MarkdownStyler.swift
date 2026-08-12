import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Applies live-preview styling to the raw markdown in an `NSTextStorage`.
///
/// The buffer always holds plain markdown — nothing is rewritten. Presentation
/// comes entirely from attributes: syntax characters get `.hiddenMD` (collapsed
/// to zero width by the layout manager) unless the caret is on their line, which
/// is what produces the "formatted until you touch it" feel.
enum MarkdownStyler {

    struct Context {
        var activeParagraphs: [NSRange] = []
        var isDark: Bool = false
        var drawingSize: (UUID) -> CGSize? = { _ in nil }
    }

    // MARK: - Metrics

    private static let bodySize: CGFloat = 15.5
    private static let lineHeightMultiple: CGFloat = 1.62
    private static let indentStep: CGFloat = 24

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 34
        case 2: return 25
        case 3: return 19
        case 4: return 17
        default: return 15.5
        }
    }

    // MARK: - Entry point

    static func style(_ storage: NSTextStorage, context: Context) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: full)

        var fenceOpen = false
        var fenceStart = 0
        var openFenceRange = NSRange(location: 0, length: 0)

        // Walk paragraphs manually so we keep the trailing newline in each range.
        var location = 0
        var lineRanges: [NSRange] = []
        while location <= text.length {
            let r = text.paragraphRange(for: NSRange(location: location, length: 0))
            lineRanges.append(r)
            if r.upperBound <= location { break }
            location = r.upperBound
            if location == text.length { break }
        }

        for range in lineRanges {
            let line = text.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .newlines)
            let isActive = context.activeParagraphs.contains { NSIntersectionRange($0, range).length > 0
                || $0.location == range.location }

            // Fenced code blocks swallow everything until they close.
            if trimmed.hasPrefix("```") {
                styleFenceLine(storage, range: range, isActive: isActive)
                if fenceOpen {
                    let blockRange = NSRange(location: fenceStart, length: range.upperBound - fenceStart)
                    applyCodeBlock(storage, blockRange: blockRange, text: text, context: context)
                    // Invisible fence rows collapse into the slab's padding.
                    collapseFenceRow(storage, range: openFenceRange, isOpening: true)
                    collapseFenceRow(storage, range: range, isOpening: false)
                    fenceOpen = false
                } else {
                    fenceOpen = true
                    fenceStart = range.location
                    openFenceRange = range
                }
                continue
            }
            if fenceOpen {
                storage.addAttribute(.font, value: Theme.mono(13.5), range: range)
                storage.addAttribute(.foregroundColor, value: Theme.textPrimary, range: range)
                continue
            }

            styleLine(storage, range: range, line: line, isActive: isActive,
                      text: text, context: context)
        }

        // An unterminated fence still gets its slab so typing inside one looks right.
        if fenceOpen {
            let blockRange = NSRange(location: fenceStart, length: text.length - fenceStart)
            applyCodeBlock(storage, blockRange: blockRange, text: text, context: context)
            collapseFenceRow(storage, range: openFenceRange, isOpening: true)
        }

        storage.endEditing()
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: Theme.body(bodySize),
            .foregroundColor: Theme.textPrimary,
            .paragraphStyle: paragraphStyle()
        ]
    }

    private static func paragraphStyle(headIndent: CGFloat = 0,
                                       firstLineIndent: CGFloat = 0,
                                       spacingBefore: CGFloat = 0,
                                       spacingAfter: CGFloat = 8,
                                       lineHeight: CGFloat = lineHeightMultiple,
                                       minimumHeight: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeight
        p.paragraphSpacing = spacingAfter
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineIndent
        if minimumHeight > 0 {
            p.minimumLineHeight = minimumHeight
            p.maximumLineHeight = minimumHeight
            p.lineHeightMultiple = 0
        }
        return p
    }

    // MARK: - Block-level

    private static func styleLine(_ storage: NSTextStorage, range: NSRange, line: String,
                                  isActive: Bool, text: NSString, context: Context) {
        let content = line.trimmingCharacters(in: .newlines)
        let leadingSpaces = content.prefix { $0 == " " || $0 == "\t" }
        let indentLevel = min(4, leadingSpaces.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
                              + leadingSpaces.filter { $0 == " " }.count / 2)
        let body = content.dropFirst(leadingSpaces.count)
        let bodyOffset = range.location + leadingSpaces.count
        let indent = CGFloat(indentLevel) * indentStep

        // ---- Embedded drawing -------------------------------------------------
        if let id = drawingID(in: String(body)) {
            let size = context.drawingSize(id) ?? CGSize(width: 400, height: 220)
            let height = max(60, size.height) + 20
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(spacingBefore: 6, spacingAfter: 10,
                                                       minimumHeight: height),
                                 range: range)
            hide(storage, NSRange(location: bodyOffset, length: body.count), active: false)
            storage.addAttribute(.drawingRef, value: id.uuidString, range: range)
            storage.addAttribute(.lineDecoration,
                                 value: LineDecoration(kind: .drawing(id: id, size: size),
                                                       indent: 0),
                                 range: range)
            return
        }

        // ---- Divider ----------------------------------------------------------
        if body == "---" || body == "***" || body == "___" {
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(spacingBefore: 10, spacingAfter: 14,
                                                       minimumHeight: 22),
                                 range: range)
            hide(storage, NSRange(location: bodyOffset, length: body.count), active: isActive)
            if isActive {
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker,
                                     range: NSRange(location: bodyOffset, length: body.count))
            }
            storage.addAttribute(.lineDecoration,
                                 value: LineDecoration(kind: .divider, indent: 0), range: range)
            return
        }

        // ---- Heading ----------------------------------------------------------
        if let (level, markerLength) = headingLevel(String(body)) {
            let size = headingSize(level)
            // Serif for the two display levels; the smaller ones stay sans so
            // they read as structure rather than title.
            let font = level <= 2 ? Theme.serif(size, weight: .medium)
                                  : Theme.body(size, weight: .semibold)
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(headIndent: indent, firstLineIndent: indent,
                                                       spacingBefore: level == 1 ? 18 : 22,
                                                       spacingAfter: 4,
                                                       lineHeight: 1.25),
                                 range: range)
            let markerRange = NSRange(location: bodyOffset, length: markerLength)
            hide(storage, markerRange, active: isActive)
            if isActive {
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: markerRange)
            }
            styleInline(storage, in: NSRange(location: bodyOffset + markerLength,
                                             length: max(0, body.count - markerLength)),
                        text: text, isActive: isActive, baseFont: font)
            return
        }

        // ---- Blockquote -------------------------------------------------------
        if body.hasPrefix("> ") || body == ">" {
            let markerLength = body.hasPrefix("> ") ? 2 : 1
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(headIndent: indent + 18,
                                                       firstLineIndent: indent + 18,
                                                       spacingAfter: 6),
                                 range: range)
            storage.addAttribute(.foregroundColor, value: Theme.accentBright, range: range)
            storage.addAttribute(.quoteBlock, value: indent, range: range)
            let markerRange = NSRange(location: bodyOffset, length: markerLength)
            hide(storage, markerRange, active: isActive)
            styleInline(storage, in: NSRange(location: bodyOffset + markerLength,
                                             length: max(0, body.count - markerLength)),
                        text: text, isActive: isActive,
                        baseFont: Theme.hand(bodySize + 4.5))
            return
        }

        // ---- Checklist --------------------------------------------------------
        if let checked = checkboxState(String(body)) {
            let markerLength = 6                       // "- [ ] "
            let hangingIndent = indent + 26
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(headIndent: hangingIndent,
                                                       firstLineIndent: hangingIndent,
                                                       spacingAfter: 3),
                                 range: range)
            let markerRange = NSRange(location: bodyOffset, length: min(markerLength, body.count))
            hide(storage, markerRange, active: isActive)
            if isActive {
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: markerRange)
            }
            // The single character between the brackets is what a click flips.
            let toggleRange = NSRange(location: bodyOffset + 3, length: 1)
            storage.addAttribute(.checkboxToggle, value: NSValue(range: toggleRange), range: range)
            storage.addAttribute(.lineDecoration,
                                 value: LineDecoration(kind: .checkbox(checked: checked,
                                                                       toggleRange: toggleRange),
                                                       indent: indent),
                                 range: range)

            let textRange = NSRange(location: bodyOffset + markerLength,
                                    length: max(0, body.count - markerLength))
            if checked {
                storage.addAttribute(.foregroundColor, value: Theme.textTertiary, range: textRange)
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: textRange)
                storage.addAttribute(.strikethroughColor, value: Theme.textTertiary, range: textRange)
            }
            styleInline(storage, in: textRange, text: text, isActive: isActive,
                        baseFont: Theme.body(bodySize))
            return
        }

        // ---- Bullet list ------------------------------------------------------
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            let hangingIndent = indent + 22
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(headIndent: hangingIndent,
                                                       firstLineIndent: hangingIndent,
                                                       spacingAfter: 3),
                                 range: range)
            let markerRange = NSRange(location: bodyOffset, length: 2)
            hide(storage, markerRange, active: isActive)
            if isActive {
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: markerRange)
            }
            storage.addAttribute(.lineDecoration,
                                 value: LineDecoration(kind: .bullet(level: indentLevel),
                                                       indent: indent),
                                 range: range)
            styleInline(storage, in: NSRange(location: bodyOffset + 2,
                                             length: max(0, body.count - 2)),
                        text: text, isActive: isActive, baseFont: Theme.body(bodySize))
            return
        }

        // ---- Ordered list -----------------------------------------------------
        if let markerLength = orderedMarkerLength(String(body)) {
            let hangingIndent = indent + 26
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(headIndent: hangingIndent,
                                                       firstLineIndent: indent,
                                                       spacingAfter: 3),
                                 range: range)
            let markerRange = NSRange(location: bodyOffset, length: markerLength)
            storage.addAttribute(.foregroundColor, value: Theme.textSecondary, range: markerRange)
            storage.addAttribute(.font, value: Theme.body(bodySize, weight: .medium), range: markerRange)
            styleInline(storage, in: NSRange(location: bodyOffset + markerLength,
                                             length: max(0, body.count - markerLength)),
                        text: text, isActive: isActive, baseFont: Theme.body(bodySize))
            return
        }

        // ---- Plain paragraph --------------------------------------------------
        if indent > 0 {
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(headIndent: indent, firstLineIndent: indent),
                                 range: range)
        }
        styleInline(storage, in: NSRange(location: bodyOffset, length: body.count),
                    text: text, isActive: isActive, baseFont: Theme.body(bodySize))
    }

    private static func styleFenceLine(_ storage: NSTextStorage, range: NSRange, isActive: Bool) {
        let hasNewline = (storage.string as NSString).substring(with: range).hasSuffix("\n")
        let r = NSRange(location: range.location, length: max(0, range.length - (hasNewline ? 1 : 0)))
        storage.addAttribute(.font, value: Theme.mono(11), range: r)
        storage.addAttribute(.foregroundColor, value: Theme.textTertiary, range: r)
        hide(storage, r, active: isActive)
    }

    /// A hidden ``` row still occupies a line. Shrink it to a few points so it
    /// reads as the slab's padding rather than a blank line.
    private static func collapseFenceRow(_ storage: NSTextStorage, range: NSRange,
                                         isOpening: Bool) {
        guard range.length > 0, range.upperBound <= storage.length else { return }
        // If the caret revealed this fence, leave it at full height so it's editable.
        guard storage.attribute(.hiddenMD, at: range.location, effectiveRange: nil) != nil else { return }
        let p = paragraphStyle(headIndent: 16, firstLineIndent: 16,
                               spacingBefore: isOpening ? 8 : 0,
                               spacingAfter: isOpening ? 0 : 12,
                               minimumHeight: 8)
        p.tailIndent = -16
        storage.addAttribute(.paragraphStyle, value: p, range: range)
    }

    private static func applyCodeBlock(_ storage: NSTextStorage, blockRange: NSRange,
                                       text: NSString, context: Context) {
        guard blockRange.length > 0, blockRange.upperBound <= text.length else { return }
        storage.addAttribute(.codeBlock, value: true, range: blockRange)
        let p = paragraphStyle(headIndent: 16, firstLineIndent: 16,
                               spacingBefore: 8, spacingAfter: 12, lineHeight: 1.42)
        p.tailIndent = -16
        storage.addAttribute(.paragraphStyle, value: p, range: blockRange)
    }

    // MARK: - Inline spans

    private static let boldRegex = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<![\\*_\\w])([\\*_])(?=[^\\s\\*_])([^\\*_]+?)\\1(?![\\*_\\w])")
    private static let codeRegex = try! NSRegularExpression(pattern: "`([^`\n]+)`")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let markRegex = try! NSRegularExpression(pattern: "==(?=\\S)(.+?)(?<=\\S)==")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]\n]*)\\]\\(([^)\\s]+)\\)")
    private static let drawingRegex = try! NSRegularExpression(pattern: "^!\\[[^\\]]*\\]\\(drawing://([0-9A-Fa-f-]{36})\\)$")

    static func drawingID(in line: String) -> UUID? {
        let ns = line as NSString
        guard let m = drawingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return UUID(uuidString: ns.substring(with: m.range(at: 1)))
    }

    private static func styleInline(_ storage: NSTextStorage, in range: NSRange,
                                    text: NSString, isActive: Bool, baseFont: PlatformFont) {
        guard range.length > 0, range.upperBound <= text.length else { return }
        let substring = text.substring(with: range)
        let local = NSRange(location: 0, length: (substring as NSString).length)
        var claimed: [NSRange] = []

        func offset(_ r: NSRange) -> NSRange {
            NSRange(location: range.location + r.location, length: r.length)
        }
        func overlapsClaimed(_ r: NSRange) -> Bool {
            claimed.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // Code spans win over everything else inside them.
        for m in codeRegex.matches(in: substring, range: local) {
            let whole = m.range, inner = m.range(at: 1)
            claimed.append(whole)
            let full = offset(whole)
            storage.addAttribute(.font, value: Theme.mono(baseFont.pointSize * 0.92), range: offset(inner))
            storage.addAttribute(.foregroundColor, value: Theme.codeText, range: offset(inner))
            storage.addAttribute(.inlineCode, value: true, range: offset(inner))
            hideTicks(storage, whole: full, inner: offset(inner), active: isActive)
        }

        for m in linkRegex.matches(in: substring, range: local) {
            let whole = m.range
            guard !overlapsClaimed(whole) else { continue }
            claimed.append(whole)
            let label = offset(m.range(at: 1))
            let url = text.substring(with: offset(m.range(at: 2)))
            storage.addAttribute(.foregroundColor, value: Theme.accent, range: label)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            storage.addAttribute(.underlineColor, value: Theme.accent.withAlphaComponent(0.4), range: label)
            if let link = URL(string: url) {
                storage.addAttribute(.link, value: link, range: label)
            }
            // Hide `[`, `](url)` so only the label shows.
            let openBracket = NSRange(location: offset(whole).location, length: 1)
            let tail = NSRange(location: label.upperBound,
                               length: offset(whole).upperBound - label.upperBound)
            hide(storage, openBracket, active: isActive)
            hide(storage, tail, active: isActive)
            if isActive {
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: openBracket)
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: tail)
            }
        }

        for m in boldRegex.matches(in: substring, range: local) {
            let whole = m.range
            guard !overlapsClaimed(whole) else { continue }
            claimed.append(whole)
            let inner = offset(m.range(at: 2))
            storage.addAttribute(.font, value: Theme.bold(baseFont), range: inner)
            hideDelimiters(storage, whole: offset(whole), inner: inner, width: 2, active: isActive)
        }

        for m in italicRegex.matches(in: substring, range: local) {
            let whole = m.range
            guard !overlapsClaimed(whole) else { continue }
            claimed.append(whole)
            let inner = offset(m.range(at: 2))
            let existing = storage.attribute(.font, at: inner.location,
                                             effectiveRange: nil) as? PlatformFont ?? baseFont
            storage.addAttribute(.font, value: Theme.italic(existing), range: inner)
            hideDelimiters(storage, whole: offset(whole), inner: inner, width: 1, active: isActive)
        }

        for m in strikeRegex.matches(in: substring, range: local) {
            let whole = m.range
            guard !overlapsClaimed(whole) else { continue }
            claimed.append(whole)
            let inner = offset(m.range(at: 1))
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: inner)
            storage.addAttribute(.foregroundColor, value: Theme.textSecondary, range: inner)
            hideDelimiters(storage, whole: offset(whole), inner: inner, width: 2, active: isActive)
        }

        for m in markRegex.matches(in: substring, range: local) {
            let whole = m.range
            guard !overlapsClaimed(whole) else { continue }
            claimed.append(whole)
            let inner = offset(m.range(at: 1))
            storage.addAttribute(.highlightSpan, value: true, range: inner)
            hideDelimiters(storage, whole: offset(whole), inner: inner, width: 2, active: isActive)
        }
    }

    // MARK: - Marker visibility

    private static func hide(_ storage: NSTextStorage, _ range: NSRange, active: Bool) {
        guard range.length > 0, range.upperBound <= storage.length else { return }
        if active {
            storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: range)
        } else {
            storage.addAttribute(.hiddenMD, value: true, range: range)
        }
    }

    private static func hideDelimiters(_ storage: NSTextStorage, whole: NSRange, inner: NSRange,
                                       width: Int, active: Bool) {
        let lead = NSRange(location: whole.location, length: width)
        let trail = NSRange(location: inner.upperBound, length: width)
        hide(storage, lead, active: active)
        hide(storage, trail, active: active)
        if active {
            storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: lead)
            storage.addAttribute(.foregroundColor, value: Theme.syntaxMarker, range: trail)
        }
    }

    private static func hideTicks(_ storage: NSTextStorage, whole: NSRange, inner: NSRange,
                                  active: Bool) {
        hideDelimiters(storage, whole: whole, inner: inner, width: 1, active: active)
    }

    // MARK: - Line classification helpers

    static func headingLevel(_ line: String) -> (level: Int, markerLength: Int)? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let after = line.index(line.startIndex, offsetBy: hashes)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return (hashes, hashes + 1)
    }

    static func checkboxState(_ line: String) -> Bool? {
        guard line.count >= 5 else { return nil }
        let lower = line.lowercased()
        if lower.hasPrefix("- [ ]") { return false }
        if lower.hasPrefix("- [x]") { return true }
        return nil
    }

    static func orderedMarkerLength(_ line: String) -> Int? {
        var digits = 0
        for ch in line {
            if ch.isNumber { digits += 1 } else { break }
        }
        guard digits > 0, digits < 5 else { return nil }
        let rest = line.dropFirst(digits)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return digits + 2
    }
}
