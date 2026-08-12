#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Collapses `.hiddenMD` runs to nothing. Using null glyphs (rather than clear
/// text or zero-size fonts) keeps character offsets intact, so the buffer stays
/// honest markdown while the syntax disappears.
///
/// This is TextKit 1, which both platforms still have. On iOS a `UITextView`
/// only uses it if you hand it a text container up front — the default
/// initialiser opts into TextKit 2, where there are no glyphs to null out.
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
                       font aFont: PlatformFont,
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
