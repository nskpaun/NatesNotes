import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit

typealias PlatformColor = NSColor
typealias PlatformFont  = NSFont
typealias PlatformImage = NSImage
typealias BezierPath    = NSBezierPath

#elseif canImport(UIKit)
import UIKit

typealias PlatformColor = UIColor
typealias PlatformFont  = UIFont
typealias PlatformImage = UIImage
typealias BezierPath    = UIBezierPath
#endif

// MARK: - Colour

/// The palette is written in sRGB, and `Theme` builds every token through this
/// one initialiser, so the two platforms agree on what a colour means.
extension PlatformColor {
    #if canImport(UIKit) && !canImport(AppKit)
    convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        self.init(red: r, green: g, blue: b, alpha: a)
    }
    #endif

    /// `labelColor` on AppKit, `label` on UIKit.
    static var platformLabel: PlatformColor {
        #if canImport(AppKit)
        return .labelColor
        #else
        return .label
        #endif
    }
}

// MARK: - Type

extension PlatformFont {
    /// `NSFont(descriptor:size:)` is failable and `UIFont(descriptor:size:)` is
    /// not, so callers get one non-optional spelling with a sensible fallback.
    static func from(descriptor: PlatformFontDescriptor, size: CGFloat,
                     fallback: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return PlatformFont(descriptor: descriptor, size: size) ?? fallback
        #else
        return PlatformFont(descriptor: descriptor, size: size)
        #endif
    }

    /// Bold/italic via descriptor traits. AppKit's `NSFontManager` has no UIKit
    /// counterpart, and traits work identically on both.
    func withTrait(bold: Bool = false, italic: Bool = false) -> PlatformFont {
        #if canImport(AppKit)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return PlatformFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return PlatformFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

#if canImport(AppKit)
typealias PlatformFontDescriptor = NSFontDescriptor
#else
typealias PlatformFontDescriptor = UIFontDescriptor
#endif

// MARK: - Bezier paths

#if canImport(UIKit) && !canImport(AppKit)
/// UIKit spells the same operations differently. Adopting AppKit's names keeps
/// the shared drawing code identical on both platforms rather than forking it.
extension UIBezierPath {
    func line(to point: CGPoint) { addLine(to: point) }

    func curve(to point: CGPoint, controlPoint1 c1: CGPoint, controlPoint2 c2: CGPoint) {
        addCurve(to: point, controlPoint1: c1, controlPoint2: c2)
    }

    func appendOval(in rect: CGRect) { append(UIBezierPath(ovalIn: rect)) }
    func appendRect(_ rect: CGRect) { append(UIBezierPath(rect: rect)) }

    /// AppKit's spelling; UIKit only offers the corner-mask form.
    func appendRoundedRect(_ rect: CGRect, xRadius: CGFloat, yRadius: CGFloat) {
        append(UIBezierPath(roundedRect: rect,
                            byRoundingCorners: .allCorners,
                            cornerRadii: CGSize(width: xRadius, height: yRadius)))
    }
}
#endif

extension BezierPath {
    /// Walks the path's segments platform-neutrally.
    ///
    /// AppKit exposes `element(at:associatedPoints:)`; UIKit exposes nothing at
    /// all. `CGPath.applyWithBlock` exists on both and is the only iteration
    /// primitive that doesn't need forking.
    func forEachSegment(_ body: (CGPathElementType, [CGPoint]) -> Void) {
        cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint:          count = 2
            case .addCurveToPoint:              count = 3
            case .closeSubpath:                 count = 0
            @unknown default:                   count = 0
            }
            var points: [CGPoint] = []
            points.reserveCapacity(count)
            for i in 0..<count { points.append(element.points[i]) }
            body(element.type, points)
        }
    }
}

extension BezierPath {
    /// Flattens the path into polylines, subdividing curves.
    ///
    /// AppKit has `flattened`, UIKit has nothing equivalent, so the subdivision
    /// is done here — which also means both platforms flatten identically
    /// instead of at whatever each framework picks for `flatness`.
    func polylines(segmentsPerCurve: Int = 16) -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var cursor = CGPoint.zero
        var subpathStart = CGPoint.zero

        func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint,
                   _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                           y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
        }

        func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u, b = 2 * u * t, d = t * t
            return CGPoint(x: a * p0.x + b * c.x + d * p1.x,
                           y: a * p0.y + b * c.y + d * p1.y)
        }

        forEachSegment { type, points in
            switch type {
            case .moveToPoint:
                if current.count > 1 { lines.append(current) }
                cursor = points[0]
                subpathStart = cursor
                current = [cursor]

            case .addLineToPoint:
                cursor = points[0]
                current.append(cursor)

            case .addQuadCurveToPoint:
                for step in 1...segmentsPerCurve {
                    let t = CGFloat(step) / CGFloat(segmentsPerCurve)
                    current.append(quad(cursor, points[0], points[1], t))
                }
                cursor = points[1]

            case .addCurveToPoint:
                for step in 1...segmentsPerCurve {
                    let t = CGFloat(step) / CGFloat(segmentsPerCurve)
                    current.append(cubic(cursor, points[0], points[1], points[2], t))
                }
                cursor = points[2]

            case .closeSubpath:
                current.append(subpathStart)
                if current.count > 1 { lines.append(current) }
                current = []
                cursor = subpathStart

            @unknown default:
                break
            }
        }
        if current.count > 1 { lines.append(current) }
        return lines
    }
}

// MARK: - Drawing context

enum Graphics {
    /// The context currently being drawn into, if any.
    static var current: CGContext? {
        #if canImport(AppKit)
        return NSGraphicsContext.current?.cgContext
        #else
        return UIGraphicsGetCurrentContext()
        #endif
    }

    static func save()    { current?.saveGState() }
    static func restore() { current?.restoreGState() }

    /// Runs `body` with `context` installed as the current context, so
    /// `BezierPath.stroke()`/`fill()` land in it on either platform.
    static func withContext(_ context: CGContext, flipped: Bool = true,
                            _ body: () -> Void) {
        #if canImport(AppKit)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        body()
        NSGraphicsContext.current = previous
        #else
        UIGraphicsPushContext(context)
        body()
        UIGraphicsPopContext()
        #endif
    }
}

// MARK: - Images

extension PlatformImage {
    static func from(cgImage: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: size)
        #else
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
        #endif
    }
}
