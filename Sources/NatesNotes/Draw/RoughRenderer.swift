import AppKit

/// Deterministic pseudo-random source. Every element carries a seed, so a shape
/// redraws with exactly the same wobble on every frame — the sketch look has to
/// be stable or the canvas shimmers while you pan.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt32) {
        state = UInt64(seed) &* 2_654_435_761 &+ 1
    }

    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 1_000_000) / 1_000_000
    }

    /// Uniform in [-x, x], scaled by roughness — Rough.js's `offsetOpt`.
    mutating func offset(_ x: CGFloat, roughness: CGFloat, gain: CGFloat = 1) -> CGFloat {
        roughness * gain * (next() * 2 * x - x)
    }
}

enum RoughRenderer {

    static let maxOffset: CGFloat = 2
    static let bowing: CGFloat = 1

    // MARK: - Primitives

    /// A single hand-drawn line: a cubic that diverges from the true path at two
    /// control points, exactly the trick Rough.js uses.
    static func line(_ a: CGPoint, _ b: CGPoint,
                     roughness: CGFloat,
                     rng: inout SeededRandom,
                     wideStart: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        let length = sqrt(lengthSq)

        // Long lines need proportionally less wobble or they read as sloppy.
        let gain: CGFloat
        if length < 200 { gain = 1 }
        else if length > 500 { gain = 0.4 }
        else { gain = -0.0016668 * length + 1.233334 }

        var off = maxOffset
        if off * off * 100 > lengthSq { off = length / 10 }
        let halfOffset = off / 2
        let diverge = 0.2 + rng.next() * 0.2

        var midDispX = bowing * maxOffset * dy / 200
        var midDispY = bowing * maxOffset * -dx / 200
        midDispX = rng.offset(midDispX, roughness: roughness, gain: gain)
        midDispY = rng.offset(midDispY, roughness: roughness, gain: gain)

        func jitter(_ amount: CGFloat) -> CGFloat {
            rng.offset(amount, roughness: roughness, gain: gain)
        }

        let startJitter = wideStart ? off : halfOffset
        let start = CGPoint(x: a.x + jitter(startJitter), y: a.y + jitter(startJitter))
        let end = CGPoint(x: b.x + jitter(startJitter), y: b.y + jitter(startJitter))

        let c1 = CGPoint(x: midDispX + a.x + dx * diverge + jitter(off),
                         y: midDispY + a.y + dy * diverge + jitter(off))
        let c2 = CGPoint(x: midDispX + a.x + 2 * dx * diverge + jitter(off),
                         y: midDispY + a.y + 2 * dy * diverge + jitter(off))

        path.move(to: start)
        path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        return path
    }

    /// Two overlapping passes — the doubled stroke is the signature of the style.
    static func doubleLine(_ a: CGPoint, _ b: CGPoint,
                           roughness: CGFloat,
                           rng: inout SeededRandom) -> NSBezierPath {
        let p = line(a, b, roughness: roughness, rng: &rng, wideStart: true)
        p.append(line(a, b, roughness: roughness, rng: &rng, wideStart: false))
        return p
    }

    /// Polygon with optionally rounded corners, each edge sketched twice.
    static func polygon(_ pts: [CGPoint], roughness: CGFloat,
                        rng: inout SeededRandom) -> NSBezierPath {
        let path = NSBezierPath()
        guard pts.count > 1 else { return path }
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            path.append(doubleLine(a, b, roughness: roughness, rng: &rng))
        }
        return path
    }

    /// Perturbed ellipse traced twice, each pass smoothed through its points.
    static func ellipse(in rect: CGRect, roughness: CGFloat,
                        rng: inout SeededRandom) -> NSBezierPath {
        let rx = max(rect.width / 2, 0.5)
        let ry = max(rect.height / 2, 0.5)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        // Step count scales with perimeter so big ellipses don't go polygonal.
        let perimeter = CGFloat.pi * 2 * sqrt((rx * rx + ry * ry) / 2)
        let steps = max(9, min(40, Int(perimeter / 12)))
        let increment = CGFloat.pi * 2 / CGFloat(steps)

        let path = NSBezierPath()
        for pass in 0..<2 {
            let jitterScale: CGFloat = pass == 0 ? 1 : 0.6
            let rxp = rx + rng.offset(rx * 0.05, roughness: roughness)
            let ryp = ry + rng.offset(ry * 0.05, roughness: roughness)
            var pts: [CGPoint] = []
            let startAngle = rng.next() * CGFloat.pi * 2
            // Overshoot slightly past 2π so the ends overlap like a real pen stroke.
            var angle = startAngle
            let limit = startAngle + CGFloat.pi * 2 + increment * 0.5
            while angle < limit {
                let jx = rng.offset(maxOffset * jitterScale, roughness: roughness)
                let jy = rng.offset(maxOffset * jitterScale, roughness: roughness)
                pts.append(CGPoint(x: center.x + rxp * cos(angle) + jx,
                                   y: center.y + ryp * sin(angle) + jy))
                angle += increment
            }
            path.append(smoothCurve(through: pts))
        }
        return path
    }

    /// Catmull-Rom through the points, converted to cubic Béziers.
    static func smoothCurve(through pts: [CGPoint], tension: CGFloat = 1) -> NSBezierPath {
        let path = NSBezierPath()
        guard pts.count > 2 else {
            if let f = pts.first { path.move(to: f) }
            for p in pts.dropFirst() { path.line(to: p) }
            return path
        }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / (6 * tension),
                             y: p1.y + (p2.y - p0.y) / (6 * tension))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / (6 * tension),
                             y: p2.y - (p3.y - p1.y) / (6 * tension))
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    // MARK: - Freehand ink

    /// Variable-width outline around a stroke, tapered at both ends. Produces a
    /// filled polygon rather than a stroked path, which is what makes freehand
    /// marks look like ink instead of wire.
    static func inkOutline(points: [CGPoint], width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count > 1 else {
            if let p = points.first {
                path.appendOval(in: CGRect(x: p.x - width / 2, y: p.y - width / 2,
                                           width: width, height: width))
            }
            return path
        }

        // Smooth the raw input a little; trackpad samples are noisy.
        let pts = simplify(points, tolerance: 0.6)
        guard pts.count > 1 else { return path }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        let n = pts.count
        let taper = min(CGFloat(n) * 0.25, 8)

        for i in 0..<n {
            let prev = pts[max(i - 1, 0)]
            let next = pts[min(i + 1, n - 1)]
            var dx = next.x - prev.x
            var dy = next.y - prev.y
            let len = max(hypot(dx, dy), 0.0001)
            dx /= len; dy /= len
            let nx = -dy, ny = dx

            // Taper the first and last few samples for a pen-lift look.
            var scale: CGFloat = 1
            let fromStart = CGFloat(i)
            let fromEnd = CGFloat(n - 1 - i)
            if fromStart < taper { scale = min(scale, 0.35 + 0.65 * (fromStart / taper)) }
            if fromEnd < taper { scale = min(scale, 0.35 + 0.65 * (fromEnd / taper)) }
            let r = width * 0.5 * scale

            left.append(CGPoint(x: pts[i].x + nx * r, y: pts[i].y + ny * r))
            right.append(CGPoint(x: pts[i].x - nx * r, y: pts[i].y - ny * r))
        }

        let outline = left + right.reversed()
        let p = smoothCurve(through: outline)
        p.close()
        return p
    }

    /// Ramer–Douglas–Peucker, keeps the shape while cutting sample count.
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxDist: CGFloat = 0
        var index = 0
        let a = pts[0], b = pts[pts.count - 1]
        for i in 1..<(pts.count - 1) {
            let d = perpendicularDistance(pts[i], a, b)
            if d > maxDist { maxDist = d; index = i }
        }
        if maxDist > tolerance {
            let head = simplify(Array(pts[0...index]), tolerance: tolerance)
            let tail = simplify(Array(pts[index...]), tolerance: tolerance)
            return head.dropLast() + tail
        }
        return [a, b]
    }

    private static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Fills

    /// Parallel sketch lines across `bounds`; the caller clips to the shape.
    static func hachure(bounds: CGRect, gap: CGFloat, angle: CGFloat,
                        roughness: CGFloat, rng: inout SeededRandom) -> NSBezierPath {
        let path = NSBezierPath()
        guard bounds.width > 0.5, bounds.height > 0.5 else { return path }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = hypot(bounds.width, bounds.height) / 2 + gap
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -dir.y, y: dir.x)

        var t = -radius
        while t <= radius {
            let base = CGPoint(x: center.x + normal.x * t, y: center.y + normal.y * t)
            let a = CGPoint(x: base.x - dir.x * radius, y: base.y - dir.y * radius)
            let b = CGPoint(x: base.x + dir.x * radius, y: base.y + dir.y * radius)
            path.append(line(a, b, roughness: roughness * 0.8, rng: &rng, wideStart: false))
            t += gap
        }
        return path
    }

    // MARK: - Arrowheads

    /// Two sketched barbs at `tip`, aimed back along the incoming direction.
    static func arrowhead(tip: CGPoint, from: CGPoint, size: CGFloat,
                          roughness: CGFloat, rng: inout SeededRandom) -> NSBezierPath {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread = CGFloat.pi / 7
        let path = NSBezierPath()
        for sign in [CGFloat(1), CGFloat(-1)] {
            let a = angle + CGFloat.pi + sign * spread
            let end = CGPoint(x: tip.x + cos(a) * size, y: tip.y + sin(a) * size)
            path.append(doubleLine(tip, end, roughness: roughness, rng: &rng))
        }
        return path
    }
}
