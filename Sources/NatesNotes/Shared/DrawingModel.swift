import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Element vocabulary

enum ElementKind: String, Codable {
    case rectangle, ellipse, diamond, arrow, line, freedraw, text
}

enum FillStyle: String, Codable, CaseIterable {
    case none, hachure, crossHatch, solid
}

enum StrokeStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted
}

enum EdgeStyle: String, Codable, CaseIterable {
    case sharp, round
}

/// A single object on the canvas. Geometry is stored as an origin + size plus,
/// for path-like kinds, a list of points in element-local space.
struct DrawElement: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: ElementKind
    var x: CGFloat = 0
    var y: CGFloat = 0
    var w: CGFloat = 0
    var h: CGFloat = 0
    var points: [CGPoint] = []          // local space, only for line/arrow/freedraw
    var pressures: [CGFloat] = []       // parallel to points, for freedraw taper

    var strokeColor: String = "#1F1F1E"
    var fillColor: String = "transparent"
    var fillStyle: FillStyle = .hachure
    var strokeStyle: StrokeStyle = .solid
    var strokeWidth: CGFloat = 2
    var roughness: CGFloat = 1.2
    var edges: EdgeStyle = .round
    var opacity: CGFloat = 1

    var text: String = ""
    var fontSize: CGFloat = 20
    var handwritten: Bool = true        // hand-drawn font vs. clean sans
    var textAlign: Int = 0              // 0 left, 1 center, 2 right

    var seed: UInt32 = UInt32.random(in: 1...100_000)
    /// Bumped whenever geometry changes so cached rough paths invalidate.
    var version: Int = 0

    var frame: CGRect {
        CGRect(x: min(x, x + w), y: min(y, y + h),
               width: abs(w), height: abs(h))
    }

    var isPath: Bool { kind == .line || kind == .arrow || kind == .freedraw }

    /// Generous hit region — thin strokes still need a comfortable grab area.
    func hitTest(_ p: CGPoint, tolerance: CGFloat = 10) -> Bool {
        let box = frame.insetBy(dx: -tolerance, dy: -tolerance)
        guard box.contains(p) else { return false }

        switch kind {
        case .text:
            return true
        case .rectangle, .diamond, .ellipse:
            if fillStyle != .none && fillColor != "transparent" { return true }
            // Outline-only: require proximity to the border.
            let inner = frame.insetBy(dx: tolerance, dy: tolerance)
            if kind == .ellipse {
                let c = CGPoint(x: frame.midX, y: frame.midY)
                let rx = max(frame.width / 2, 0.01), ry = max(frame.height / 2, 0.01)
                let d = pow((p.x - c.x) / rx, 2) + pow((p.y - c.y) / ry, 2)
                return d > 0.55 && d < 1.5
            }
            return !inner.contains(p) || inner.isEmpty
        case .line, .arrow, .freedraw:
            let origin = CGPoint(x: x, y: y)
            for i in 0..<max(points.count - 1, 0) {
                let a = CGPoint(x: points[i].x + origin.x, y: points[i].y + origin.y)
                let b = CGPoint(x: points[i + 1].x + origin.x, y: points[i + 1].y + origin.y)
                if distance(from: p, toSegment: a, b) < tolerance { return true }
            }
            return false
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Scene

struct Drawing: Codable, Equatable {
    var id: UUID = UUID()
    var elements: [DrawElement] = []
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    var zoom: CGFloat = 1

    /// Tight bounds around all content, in scene coordinates.
    var contentBounds: CGRect? {
        var box: CGRect?
        for e in elements {
            let f = e.frame.insetBy(dx: -e.strokeWidth * 2, dy: -e.strokeWidth * 2)
            box = box.map { $0.union(f) } ?? f
        }
        return box
    }
}

// MARK: - Color helpers

extension PlatformColor {
    /// Parses `#RGB`, `#RRGGBB`, `#RRGGBBAA` and the literal `transparent`.
    static func fromHex(_ s: String) -> PlatformColor? {
        if s == "transparent" { return nil }
        var str = s.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("#") { str.removeFirst() }
        if str.count == 3 {
            str = str.map { "\($0)\($0)" }.joined()
        }
        guard let v = UInt64(str, radix: 16) else { return nil }
        switch str.count {
        case 6:
            return PlatformColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        case 8:
            return PlatformColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255,
                           green: CGFloat((v >> 16) & 0xFF) / 255,
                           blue: CGFloat((v >> 8) & 0xFF) / 255,
                           alpha: CGFloat(v & 0xFF) / 255)
        default:
            return nil
        }
    }
}

// MARK: - Palettes (Excalidraw-flavoured, tuned for both appearances)

enum Palette {
    static let strokes = ["#1F1F1E", "#E03131", "#2F9E44", "#1971C2", "#F08C00", "#9C36B5", "#0C8599"]
    static let fills   = ["transparent", "#FFC9C9", "#B2F2BB", "#A5D8FF", "#FFEC99", "#E5DBFF", "#C5F6FA"]

    /// Dark mode needs the near-black stroke swapped for a near-white one.
    static func resolveStroke(_ hex: String, isDark: Bool) -> PlatformColor {
        if hex == "#1F1F1E" && isDark { return PlatformColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1) }
        return PlatformColor.fromHex(hex) ?? .platformLabel
    }

    /// On a dark canvas the pastels blow out, so they get pulled back — but thin
    /// hachure strokes need much more of the colour left in them than a solid
    /// wash does, or they read as plain grey.
    static func resolveFill(_ hex: String, isDark: Bool, isLineWork: Bool = false) -> PlatformColor? {
        guard let c = PlatformColor.fromHex(hex) else { return nil }
        guard isDark else { return c }
        return c.withAlphaComponent(isLineWork ? 0.72 : 0.35)
    }
}

/// `id` already exists; this just lets SwiftUI present one directly.
extension Drawing: Identifiable {}
