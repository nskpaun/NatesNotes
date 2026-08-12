import AppKit

extension NSBezierPath {
    /// A copy containing only the first `fraction` of this path's length.
    ///
    /// Flattening first means curves, multi-pass sketch strokes and arrowheads
    /// all trim uniformly, so a shape reveals in the order it was drawn.
    func trimmed(to fraction: CGFloat) -> NSBezierPath {
        guard fraction < 0.999 else { return self }
        let result = NSBezierPath()
        result.lineWidth = lineWidth
        result.lineCapStyle = lineCapStyle
        result.lineJoinStyle = lineJoinStyle
        guard fraction > 0.001 else { return result }

        // Break the flattened path into polylines.
        let flat = flattened
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<flat.elementCount {
            switch flat.element(at: index, associatedPoints: &points) {
            case .moveTo:
                if current.count > 1 { subpaths.append(current) }
                current = [points[0]]
            case .lineTo:
                current.append(points[0])
            case .closePath:
                if let first = current.first { current.append(first) }
                if current.count > 1 { subpaths.append(current) }
                current = []
            default:
                break
            }
        }
        if current.count > 1 { subpaths.append(current) }

        let total = subpaths.reduce(CGFloat(0)) { sum, line in
            sum + zip(line, line.dropFirst()).reduce(CGFloat(0)) {
                $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }
        }
        guard total > 0 else { return result }

        var budget = total * fraction
        for line in subpaths {
            guard budget > 0 else { break }
            result.move(to: line[0])
            for (a, b) in zip(line, line.dropFirst()) {
                let length = hypot(b.x - a.x, b.y - a.y)
                if length <= budget {
                    result.line(to: b)
                    budget -= length
                } else {
                    // Partial segment: stop mid-stroke, like a lifted pen.
                    let t = length > 0 ? budget / length : 0
                    result.line(to: CGPoint(x: a.x + (b.x - a.x) * t,
                                            y: a.y + (b.y - a.y) * t))
                    budget = 0
                    break
                }
            }
        }
        return result
    }
}

/// Turns a `DrawElement` into pixels. Kept separate from the canvas view so the
/// same code paints the live canvas, the inline note thumbnails and PNG exports.
enum ElementPainter {

    // MARK: - Fonts

    private static let handCandidates = ["Virgil", "Bradley Hand", "Chalkboard SE", "Marker Felt", "Noteworthy"]

    static func font(for e: DrawElement) -> NSFont {
        if e.handwritten {
            for name in handCandidates {
                if let f = NSFont(name: name, size: e.fontSize) { return f }
            }
        }
        return NSFont.systemFont(ofSize: e.fontSize, weight: .regular)
    }

    static func attributes(for e: DrawElement, isDark: Bool) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = [.left, .center, .right][max(0, min(2, e.textAlign))]
        para.lineHeightMultiple = 1.15
        return [
            .font: font(for: e),
            .foregroundColor: Palette.resolveStroke(e.strokeColor, isDark: isDark)
                .withAlphaComponent(e.opacity),
            .paragraphStyle: para
        ]
    }

    static func measuredSize(for e: DrawElement, isDark: Bool) -> CGSize {
        let s = NSAttributedString(string: e.text.isEmpty ? " " : e.text,
                                   attributes: attributes(for: e, isDark: isDark))
        let bounds = s.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width) + 4, height: ceil(bounds.height) + 4)
    }

    // MARK: - Entry point

    /// `reveal` < 1 draws the element part-way through being sketched: outlines
    /// trim to a fraction of their length, fills and text fade up. This is what
    /// makes a drawing appear to draw itself when the modal opens.
    static func draw(_ e: DrawElement, isDark: Bool, reveal: CGFloat) {
        guard reveal > 0.001 else { return }
        guard reveal < 0.999 else { return draw(e, isDark: isDark) }

        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        ctx.cgContext.setLineCap(.round)
        ctx.cgContext.setLineJoin(.round)
        var rng = SeededRandom(seed: e.seed)
        let stroke = Palette.resolveStroke(e.strokeColor, isDark: isDark)

        switch e.kind {
        case .text:
            // Text can't be trimmed meaningfully, so it fades and settles.
            ctx.cgContext.setAlpha(e.opacity * reveal)
            var scaled = e
            scaled.y += (1 - reveal) * 6
            drawText(scaled, isDark: isDark)

        case .freedraw:
            // Ink is a filled outline; reveal by drawing only the leading part
            // of the stroke, which reads exactly like a pen moving.
            ctx.cgContext.setAlpha(e.opacity)
            var partial = e
            let keep = max(2, Int(CGFloat(e.points.count) * reveal))
            partial.points = Array(e.points.prefix(keep))
            drawFreehand(partial, stroke: stroke)

        case .rectangle, .diamond, .ellipse, .line, .arrow:
            // Fills come up under the outline as it completes.
            let fillReveal = max(0, (reveal - 0.35) / 0.65)
            if fillReveal > 0.01, e.fillStyle != .none,
               e.kind == .rectangle || e.kind == .diamond || e.kind == .ellipse {
                ctx.cgContext.setAlpha(e.opacity * fillReveal)
                var fillOnly = e
                fillOnly.strokeColor = "transparent"
                drawFillOnly(fillOnly, isDark: isDark, rng: &rng)
            }
            ctx.cgContext.setAlpha(e.opacity)
            var outlineRNG = SeededRandom(seed: e.seed)
            let path = outlinePath(e, rng: &outlineRNG)
            applyStrokeStyle(path, e)
            stroke.setStroke()
            path.trimmed(to: reveal).stroke()
        }
    }

    /// The sketched outline for any element, without fill.
    private static func outlinePath(_ e: DrawElement, rng: inout SeededRandom) -> NSBezierPath {
        switch e.kind {
        case .ellipse:
            return RoughRenderer.ellipse(in: e.frame, roughness: e.roughness, rng: &rng)
        case .diamond:
            let pts = diamondPoints(e.frame)
            return e.edges == .round
                ? roughRoundedPolygon(pts, radius: cornerRadius(e.frame, factor: 0.18),
                                      roughness: e.roughness, rng: &rng)
                : RoughRenderer.polygon(pts, roughness: e.roughness, rng: &rng)
        case .rectangle:
            let r = e.frame
            let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return e.edges == .round
                ? roughRoundedPolygon(pts, radius: cornerRadius(r, factor: 0.25),
                                      roughness: e.roughness, rng: &rng)
                : RoughRenderer.polygon(pts, roughness: e.roughness, rng: &rng)
        case .line, .arrow:
            let origin = CGPoint(x: e.x, y: e.y)
            let pts = e.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            let path = NSBezierPath()
            guard pts.count >= 2 else { return path }
            for i in 0..<(pts.count - 1) {
                path.append(RoughRenderer.doubleLine(pts[i], pts[i + 1],
                                                     roughness: e.roughness, rng: &rng))
            }
            if e.kind == .arrow {
                let size = min(30, max(12, e.strokeWidth * 6 + 8))
                path.append(RoughRenderer.arrowhead(tip: pts[pts.count - 1],
                                                    from: pts[pts.count - 2], size: size,
                                                    roughness: e.roughness, rng: &rng))
            }
            return path
        case .freedraw, .text:
            return NSBezierPath()
        }
    }

    private static func drawFillOnly(_ e: DrawElement, isDark: Bool, rng: inout SeededRandom) {
        guard let fill = Palette.resolveFill(e.fillColor, isDark: isDark,
                                             isLineWork: e.fillStyle != .solid) else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        smoothShapePath(e).addClip()
        switch e.fillStyle {
        case .solid:
            fill.setFill()
            smoothShapePath(e).fill()
        case .hachure, .crossHatch:
            fill.setStroke()
            let gap = max(4, 8 - e.strokeWidth)
            let h = RoughRenderer.hachure(bounds: e.frame, gap: gap, angle: -.pi / 4,
                                          roughness: e.roughness, rng: &rng)
            h.lineWidth = max(1, e.strokeWidth * 0.6)
            h.stroke()
            if e.fillStyle == .crossHatch {
                let h2 = RoughRenderer.hachure(bounds: e.frame, gap: gap, angle: .pi / 4,
                                               roughness: e.roughness, rng: &rng)
                h2.lineWidth = max(1, e.strokeWidth * 0.6)
                h2.stroke()
            }
        case .none:
            break
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    static func draw(_ e: DrawElement, isDark: Bool) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.cgContext.setAlpha(e.opacity)
        ctx.cgContext.setLineCap(.round)
        ctx.cgContext.setLineJoin(.round)

        var rng = SeededRandom(seed: e.seed)
        let stroke = Palette.resolveStroke(e.strokeColor, isDark: isDark)

        switch e.kind {
        case .rectangle, .diamond, .ellipse:
            drawClosedShape(e, stroke: stroke, isDark: isDark, rng: &rng)
        case .line, .arrow:
            drawPathElement(e, stroke: stroke, rng: &rng)
        case .freedraw:
            drawFreehand(e, stroke: stroke)
        case .text:
            drawText(e, isDark: isDark)
        }

        ctx.restoreGraphicsState()
    }

    // MARK: - Closed shapes

    private static func drawClosedShape(_ e: DrawElement, stroke: NSColor,
                                        isDark: Bool, rng: inout SeededRandom) {
        let rect = e.frame
        guard rect.width > 0.5 || rect.height > 0.5 else { return }

        // Fill goes down first, clipped to the true (non-sketchy) silhouette.
        if e.fillStyle != .none,
           let fill = Palette.resolveFill(e.fillColor, isDark: isDark,
                                          isLineWork: e.fillStyle != .solid) {
            NSGraphicsContext.current?.saveGraphicsState()
            let clip = smoothShapePath(e)
            clip.addClip()

            switch e.fillStyle {
            case .solid:
                fill.setFill()
                clip.fill()
            case .hachure, .crossHatch:
                fill.setStroke()
                let gap = max(4, 8 - e.strokeWidth)
                let h = RoughRenderer.hachure(bounds: rect, gap: gap, angle: -.pi / 4,
                                              roughness: e.roughness, rng: &rng)
                h.lineWidth = max(1, e.strokeWidth * 0.6)
                h.lineCapStyle = .round
                h.stroke()
                if e.fillStyle == .crossHatch {
                    let h2 = RoughRenderer.hachure(bounds: rect, gap: gap, angle: .pi / 4,
                                                   roughness: e.roughness, rng: &rng)
                    h2.lineWidth = max(1, e.strokeWidth * 0.6)
                    h2.lineCapStyle = .round
                    h2.stroke()
                }
            case .none:
                break
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Then the sketchy outline on top.
        let path: NSBezierPath
        switch e.kind {
        case .ellipse:
            path = RoughRenderer.ellipse(in: rect, roughness: e.roughness, rng: &rng)
        case .diamond:
            let pts = diamondPoints(rect)
            path = e.edges == .round
                ? roughRoundedPolygon(pts, radius: cornerRadius(rect, factor: 0.18),
                                      roughness: e.roughness, rng: &rng)
                : RoughRenderer.polygon(pts, roughness: e.roughness, rng: &rng)
        default:
            let pts = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            path = e.edges == .round
                ? roughRoundedPolygon(pts, radius: cornerRadius(rect, factor: 0.25),
                                      roughness: e.roughness, rng: &rng)
                : RoughRenderer.polygon(pts, roughness: e.roughness, rng: &rng)
        }

        applyStrokeStyle(path, e)
        stroke.setStroke()
        path.stroke()
    }

    static func cornerRadius(_ rect: CGRect, factor: CGFloat) -> CGFloat {
        min(min(rect.width, rect.height) * factor, 32)
    }

    static func diamondPoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// Clean silhouette used for clipping fills and for hit-testing.
    static func smoothShapePath(_ e: DrawElement) -> NSBezierPath {
        let rect = e.frame
        switch e.kind {
        case .ellipse:
            return NSBezierPath(ovalIn: rect)
        case .diamond:
            let pts = diamondPoints(rect)
            guard e.edges == .round else {
                let p = NSBezierPath()
                p.move(to: pts[0])
                for q in pts.dropFirst() { p.line(to: q) }
                p.close()
                return p
            }
            // Match the rounded corners of the sketched outline, or the fill spills.
            return roundedPolygonPath(pts, radius: cornerRadius(rect, factor: 0.18))
        default:
            let r = e.edges == .round ? cornerRadius(rect, factor: 0.25) : 0
            return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        }
    }

    /// Clean rounded polygon — the silhouette its sketched twin approximates.
    static func roundedPolygonPath(_ pts: [CGPoint], radius: CGFloat) -> NSBezierPath {
        let n = pts.count
        let path = NSBezierPath()
        guard n > 2, radius > 1 else {
            guard let first = pts.first else { return path }
            path.move(to: first)
            for q in pts.dropFirst() { path.line(to: q) }
            path.close()
            return path
        }
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n]
            let entry = pointToward(from: cur, to: prev, distance: radius)
            let exit = pointToward(from: cur, to: next, distance: radius)
            if i == 0 { path.move(to: entry) } else { path.line(to: entry) }
            let c1 = CGPoint(x: entry.x + 2.0 / 3.0 * (cur.x - entry.x),
                             y: entry.y + 2.0 / 3.0 * (cur.y - entry.y))
            let c2 = CGPoint(x: exit.x + 2.0 / 3.0 * (cur.x - exit.x),
                             y: exit.y + 2.0 / 3.0 * (cur.y - exit.y))
            path.curve(to: exit, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        return path
    }

    /// Polygon whose corners are eased with quadratic curves and whose edges are
    /// sketched — the rounded-rectangle look.
    static func roughRoundedPolygon(_ pts: [CGPoint], radius: CGFloat,
                                    roughness: CGFloat, rng: inout SeededRandom) -> NSBezierPath {
        let n = pts.count
        guard n > 2, radius > 1 else {
            return RoughRenderer.polygon(pts, roughness: roughness, rng: &rng)
        }
        var entry = [CGPoint](repeating: .zero, count: n)
        var exit = [CGPoint](repeating: .zero, count: n)

        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n]
            entry[i] = pointToward(from: cur, to: prev, distance: radius)
            exit[i] = pointToward(from: cur, to: next, distance: radius)
        }

        let path = NSBezierPath()
        for i in 0..<n {
            // Straight run to the next corner…
            path.append(RoughRenderer.doubleLine(exit[i], entry[(i + 1) % n],
                                                 roughness: roughness, rng: &rng))
            // …then the corner itself, as a quadratic promoted to cubic.
            let a = entry[i], b = exit[i], c = pts[i]
            let c1 = CGPoint(x: a.x + 2.0 / 3.0 * (c.x - a.x), y: a.y + 2.0 / 3.0 * (c.y - a.y))
            let c2 = CGPoint(x: b.x + 2.0 / 3.0 * (c.x - b.x), y: b.y + 2.0 / 3.0 * (c.y - b.y))
            path.move(to: a)
            path.curve(to: b, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    private static func pointToward(from a: CGPoint, to b: CGPoint, distance: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.0001)
        let d = min(distance, len / 2)
        return CGPoint(x: a.x + dx / len * d, y: a.y + dy / len * d)
    }

    // MARK: - Lines and arrows

    private static func drawPathElement(_ e: DrawElement, stroke: NSColor,
                                        rng: inout SeededRandom) {
        let origin = CGPoint(x: e.x, y: e.y)
        let pts = e.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        guard pts.count >= 2 else { return }

        let path = NSBezierPath()
        if pts.count == 2 {
            path.append(RoughRenderer.doubleLine(pts[0], pts[1],
                                                 roughness: e.roughness, rng: &rng))
        } else {
            // Multi-point: sketch each leg so the whole polyline wobbles coherently.
            for i in 0..<(pts.count - 1) {
                path.append(RoughRenderer.doubleLine(pts[i], pts[i + 1],
                                                     roughness: e.roughness, rng: &rng))
            }
        }

        if e.kind == .arrow {
            let size = min(30, max(12, e.strokeWidth * 6 + 8))
            path.append(RoughRenderer.arrowhead(tip: pts[pts.count - 1],
                                                from: pts[pts.count - 2],
                                                size: size,
                                                roughness: e.roughness, rng: &rng))
        }

        applyStrokeStyle(path, e)
        stroke.setStroke()
        path.stroke()
    }

    // MARK: - Freehand

    private static func drawFreehand(_ e: DrawElement, stroke: NSColor) {
        let origin = CGPoint(x: e.x, y: e.y)
        let pts = e.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        guard !pts.isEmpty else { return }
        let outline = RoughRenderer.inkOutline(points: pts, width: max(2, e.strokeWidth * 1.6))
        stroke.setFill()
        outline.fill()
    }

    // MARK: - Text

    private static func drawText(_ e: DrawElement, isDark: Bool) {
        guard !e.text.isEmpty else { return }
        let s = NSAttributedString(string: e.text, attributes: attributes(for: e, isDark: isDark))
        let rect = CGRect(x: e.frame.minX, y: e.frame.minY,
                          width: max(e.frame.width, 1), height: max(e.frame.height, 1))
        s.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // MARK: - Shared

    private static func applyStrokeStyle(_ path: NSBezierPath, _ e: DrawElement) {
        path.lineWidth = e.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch e.strokeStyle {
        case .solid: break
        case .dashed:
            let p: [CGFloat] = [e.strokeWidth * 4, e.strokeWidth * 3]
            path.setLineDash(p, count: 2, phase: 0)
        case .dotted:
            let p: [CGFloat] = [0.01, e.strokeWidth * 2.6]
            path.setLineDash(p, count: 2, phase: 0)
            path.lineCapStyle = .round
        }
    }

    // MARK: - Rasterising a whole scene

    /// Renders a drawing to an image, fitted into `maxSize` with padding. Used for
    /// the inline thumbnails in notes and for PNG export.
    static func image(for drawing: Drawing, maxSize: CGSize, isDark: Bool,
                      scale: CGFloat = 2, padding: CGFloat = 16,
                      background: NSColor? = nil) -> NSImage? {
        guard let bounds = drawing.contentBounds, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let padded = bounds.insetBy(dx: -padding, dy: -padding)
        let fit = min(maxSize.width / padded.width, maxSize.height / padded.height, 3)
        let size = CGSize(width: max(1, padded.width * fit), height: max(1, padded.height * fit))

        let pixelW = Int(size.width * scale), pixelH = Int(size.height * scale)
        guard pixelW > 0, pixelH > 0,
              let cg = CGContext(data: nil, width: pixelW, height: pixelH,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // `flipped: true` keeps AppKit text upright once we invert the CTM below.
        let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        cg.scaleBy(x: scale, y: scale)
        if let bg = background {
            cg.setFillColor(bg.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
        }
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)                     // now y-down, matching scene space
        cg.scaleBy(x: fit, y: fit)
        cg.translateBy(x: -padded.minX, y: -padded.minY)

        for e in drawing.elements { draw(e, isDark: isDark) }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cg.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
