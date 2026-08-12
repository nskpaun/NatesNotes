import SwiftUI
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The two working states. Everything accent-coloured keys off this, so
/// switching modes re-tints the whole app in one move.
enum AppMode: String, Codable {
    case chill, lockedIn

    var label: String { self == .chill ? "Chill Mode" : "Locked-In Mode" }
    var shortLabel: String { self == .chill ? "Chill" : "Locked-In" }
    var glyph: String { self == .chill ? "水" : "◎" }
    var symbol: String { self == .chill ? "water.waves" : "target" }

    /// Cool blue when thinking, warm amber when executing.
    var accent: PlatformColor {
        self == .chill ? OKLCH(0.78, 0.13, 250).platformColor : OKLCH(0.80, 0.13, 78).platformColor
    }

    var accentBright: PlatformColor {
        self == .chill ? OKLCH(0.87, 0.11, 250).platformColor : OKLCH(0.90, 0.10, 78).platformColor
    }

    var toggled: AppMode { self == .chill ? .lockedIn : .chill }
}

/// OKLCH is what the design is specified in, so the palette is transcribed
/// directly rather than eyeballed into hex.
struct OKLCH {
    var l: CGFloat, c: CGFloat, h: CGFloat, alpha: CGFloat

    init(_ l: CGFloat, _ c: CGFloat, _ h: CGFloat, _ alpha: CGFloat = 1) {
        self.l = l; self.c = c; self.h = h; self.alpha = alpha
    }

    var platformColor: PlatformColor {
        let hRad = h * .pi / 180
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        // OKLab → LMS
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_

        // LMS → linear sRGB
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        func encode(_ v: CGFloat) -> CGFloat {
            let clamped = max(0, min(1, v))
            return clamped <= 0.0031308 ? 12.92 * clamped
                                        : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return PlatformColor(srgbRed: encode(r), green: encode(g), blue: encode(bl), alpha: alpha)
    }

    var color: Color { Color(platformColor) }
}

/// Design tokens. Midnight navy, near-black, with a single accent that follows
/// the current mode.
enum Theme {

    // MARK: - Mode (shared with the AppKit layers, which can't see SwiftUI state)

    /// Mirrors `AppState.mode` so `MarkdownStyler` and `CanvasView` can tint
    /// themselves without threading the environment through AppKit.
    nonisolated(unsafe) static var mode: AppMode = .chill

    static var accent: PlatformColor { mode.accent }
    static var accentBright: PlatformColor { mode.accentBright }

    // MARK: - Palette

    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> PlatformColor {
        PlatformColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: a)
    }

    private static func white(_ a: CGFloat) -> PlatformColor {
        PlatformColor(srgbRed: 1, green: 1, blue: 1, alpha: a)
    }

    // Surfaces
    static let windowBG   = hex(0x0B0E17)
    static let canvasBG   = hex(0x0B0E17)
    static let panelBG    = hex(0x0D111C)
    static let sidebarBG  = hex(0x090C14)
    static let raisedBG   = hex(0x141926)
    static let sunkenBG   = hex(0x070910)
    static let scrimBG    = PlatformColor(srgbRed: 0.02, green: 0.03, blue: 0.05, alpha: 0.62)

    static let hoverBG    = white(0.05)
    static let selectedBG = white(0.075)
    static let hairline   = white(0.07)
    static let hairlineStrong = white(0.11)

    // Text
    static let textPrimary   = white(0.95)
    static let textSecondary = white(0.68)
    static let textTertiary  = white(0.42)
    static let textFaint     = white(0.26)
    static let syntaxMarker  = white(0.22)

    // Editorial
    static var codeText: PlatformColor { OKLCH(0.82, 0.11, 30).platformColor }
    static let codeBG      = white(0.045)
    static var quoteBar: PlatformColor { accent.withAlphaComponent(0.55) }
    static var highlightBG: PlatformColor { accent.withAlphaComponent(0.20) }
    static var checkDone: PlatformColor { accent }
    static let dotGrid     = white(0.065)

    // MARK: - Typography

    /// Editorial serif for display text — New York is the system serif and is
    /// the closest native stand-in for the design's Newsreader.
    static func serif(_ size: CGFloat, weight: PlatformFont.Weight = .medium) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return PlatformFont.from(descriptor: descriptor, size: size, fallback: base)
    }

    static func body(_ size: CGFloat = 15.5, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        PlatformFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 12, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Hand-drawn face for sketch text, matching the design's Caveat.
    static func hand(_ size: CGFloat) -> PlatformFont {
        for name in ["Caveat", "Bradley Hand", "Chalkboard SE", "Marker Felt", "Noteworthy"] {
            if let font = PlatformFont(name: name, size: size) { return font }
        }
        return serif(size, weight: .regular)
    }

    static func italic(_ font: PlatformFont) -> PlatformFont { font.withTrait(italic: true) }

    static func bold(_ font: PlatformFont) -> PlatformFont { font.withTrait(bold: true) }

    // MARK: - Metrics

    static let editorMaxWidth: CGFloat = 700
    static let editorHPadding: CGFloat = 52
    static let windowCorner: CGFloat = 14
    static let titleBarHeight: CGFloat = 46
    static let statusBarHeight: CGFloat = 38
    static let sidebarWidth: CGFloat = 214
}

// MARK: - SwiftUI bridges

extension Color {
    init(_ platform: PlatformColor) {
        #if canImport(AppKit)
        self = Color(nsColor: platform)
        #else
        self = Color(uiColor: platform)
        #endif
    }
}

extension Theme {
    static var sAccent: Color { Color(accent) }
    static var sAccentBright: Color { Color(accentBright) }
    static var sWindow: Color { Color(windowBG) }
    static var sPanel: Color { Color(panelBG) }
    static var sSidebar: Color { Color(sidebarBG) }
    static var sRaised: Color { Color(raisedBG) }
    static var sSunken: Color { Color(sunkenBG) }
    static var sTextPrimary: Color { Color(textPrimary) }
    static var sTextSecondary: Color { Color(textSecondary) }
    static var sTextTertiary: Color { Color(textTertiary) }
    static var sTextFaint: Color { Color(textFaint) }
    static var sHairline: Color { Color(hairline) }
    static var sHover: Color { Color(hoverBG) }
    static var sSelected: Color { Color(selectedBG) }
}

// MARK: - Motion

/// One place for timing, so the whole app moves with the same character.
enum Motion {
    /// Default for anything that appears or repositions.
    static let spring = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Snappier, for direct manipulation feedback.
    static let snappy = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// The big one — the drawing modal morph.
    static let hero = SwiftUI.Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// Colour and opacity cross-fades.
    static let fade = SwiftUI.Animation.easeOut(duration: 0.22)
    /// Mode switching, which re-tints a lot of surface at once.
    static let mode = SwiftUI.Animation.easeInOut(duration: 0.5)

    /// Staggered delay for list-style entrances.
    static func stagger(_ index: Int, step: Double = 0.035, cap: Int = 12) -> SwiftUI.Animation {
        spring.delay(Double(min(index, cap)) * step)
    }
}
