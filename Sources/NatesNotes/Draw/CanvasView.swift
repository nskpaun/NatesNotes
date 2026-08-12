import AppKit

protocol CanvasViewDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasView)
    func canvasDidChangeSelection(_ canvas: CanvasView)
    /// Fired when a drag with a shape tool finishes, so the UI can drop back to select.
    func canvasDidFinishCreating(_ canvas: CanvasView)
}

/// The infinite sketch surface. Owns hit-testing, direct manipulation, undo and
/// the viewport transform; all painting delegates to `ElementPainter`.
final class CanvasView: NSView, NSTextViewDelegate {

    weak var delegate: CanvasViewDelegate?

    var drawing = Drawing() { didSet { needsDisplay = true } }
    var style = DrawStyle() { didSet { needsDisplay = true } }
    var tool: CanvasTool = .select {
        didSet {
            if tool != .select { selection.removeAll() }
            endTextEditing(commit: true)
            updateCursor()
            needsDisplay = true
        }
    }
    var showGrid = true { didSet { needsDisplay = true } }
    var selection: Set<UUID> = [] {
        didSet {
            if selection != oldValue { delegate?.canvasDidChangeSelection(self) }
            needsDisplay = true
        }
    }

    // Viewport
    private var scroll = CGPoint.zero          // scene point at the view's top-left
    private var zoom: CGFloat = 1

    // Interaction state
    private enum DragMode {
        case none, creating, moving, marquee, panning
        case resizing(handle: Int)
        case endpoint(index: Int)

        /// Selection chrome hides mid-gesture to keep drags visually clean.
        var isQuiet: Bool {
            switch self {
            case .none, .resizing, .endpoint: return true
            default: return false
            }
        }
    }
    private var dragMode: DragMode = .none
    private var dragStartScene = CGPoint.zero
    private var dragOriginals: [UUID: DrawElement] = [:]
    private var marqueeRect: CGRect?
    private var liveElementID: UUID?
    private var spaceHeld = false
    private var hoverEraseIDs: Set<UUID> = []

    // Undo
    private var undoStack: [[DrawElement]] = []
    private var redoStack: [[DrawElement]] = []

    // MARK: - Ink reveal

    /// 0…1 across the whole scene. Below 1, elements draw themselves in order.
    private(set) var revealProgress: CGFloat = 1
    private var revealTimer: Timer?

    /// Plays the sketch back as if it were being drawn by hand. Used when the
    /// drawing modal opens, so the diagram arrives rather than just appearing.
    func playInkReveal(duration: TimeInterval = 1.15) {
        revealTimer?.invalidate()
        guard !drawing.elements.isEmpty else { revealProgress = 1; return }

        revealProgress = 0
        needsDisplay = true
        let start = Date()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, CGFloat(Date().timeIntervalSince(start) / duration))
            self.revealProgress = t
            self.needsDisplay = true
            if t >= 1 { timer.invalidate(); self.revealTimer = nil }
        }
        if let revealTimer { RunLoop.main.add(revealTimer, forMode: .common) }
    }

    func finishInkReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        revealProgress = 1
        needsDisplay = true
    }

    /// Per-element slice of the global timeline. Windows overlap so the pen
    /// appears to flow between shapes rather than pausing between them.
    private func revealFraction(forElement index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return eased(revealProgress) }
        let window = min(0.6, max(0.18, 1.6 / CGFloat(count)))
        let step = (1 - window) / CGFloat(count - 1)
        let local = (revealProgress - CGFloat(index) * step) / window
        return eased(max(0, min(1, local)))
    }

    private func eased(_ t: CGFloat) -> CGFloat {
        // easeOutCubic: fast attack, gentle settle — reads like a real stroke.
        1 - pow(1 - max(0, min(1, t)), 3)
    }

    // Text editing
    private var textEditor: NSTextView?
    private var editingElementID: UUID?

    private let handleSize: CGFloat = 9

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Coordinate transforms

    func toScene(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + scroll.x, y: p.y / zoom + scroll.y)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - scroll.x) * zoom, y: (p.y - scroll.y) * zoom)
    }

    func toViewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    var zoomLevel: CGFloat { zoom }

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let clamped = max(0.1, min(8, newZoom))
        let anchorView = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let sceneAnchor = toScene(anchorView)
        zoom = clamped
        // Keep the anchor pinned under the cursor.
        scroll = CGPoint(x: sceneAnchor.x - anchorView.x / zoom,
                         y: sceneAnchor.y - anchorView.y / zoom)
        needsDisplay = true
        delegate?.canvasDidChangeSelection(self)
    }

    func resetZoom() { setZoom(1) }

    func zoomToFit() {
        guard let content = drawing.contentBounds, content.width > 1, content.height > 1 else {
            zoom = 1; scroll = .zero; needsDisplay = true; return
        }
        let padded = content.insetBy(dx: -40, dy: -40)
        zoom = max(0.1, min(2, min(bounds.width / padded.width, bounds.height / padded.height)))
        scroll = CGPoint(x: padded.midX - bounds.width / (2 * zoom),
                         y: padded.midY - bounds.height / (2 * zoom))
        needsDisplay = true
        delegate?.canvasDidChangeSelection(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        Theme.canvasBG.setFill()
        bounds.fill()

        if showGrid { drawGrid() }

        ctx.saveGraphicsState()
        ctx.cgContext.scaleBy(x: zoom, y: zoom)
        ctx.cgContext.translateBy(x: -scroll.x, y: -scroll.y)

        let count = drawing.elements.count
        for (index, e) in drawing.elements.enumerated() {
            if e.id == editingElementID { continue }   // being edited in the overlay
            var painted = e
            if hoverEraseIDs.contains(e.id) { painted.opacity *= 0.25 }
            if revealProgress < 0.999 {
                ElementPainter.draw(painted, isDark: isDark,
                                    reveal: revealFraction(forElement: index, of: count))
            } else {
                ElementPainter.draw(painted, isDark: isDark)
            }
        }

        ctx.restoreGraphicsState()

        drawSelectionChrome()

        if let m = marqueeRect {
            let r = toViewRect(m)
            Theme.accent.withAlphaComponent(0.12).setFill()
            r.fill()
            Theme.accent.withAlphaComponent(0.7).setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func drawGrid() {
        let spacing: CGFloat = 22
        let step = spacing * zoom
        guard step > 6 else { return }
        let color = Theme.textPrimary.withAlphaComponent(isDark ? 0.09 : 0.075)
        color.setFill()

        let startX = -((scroll.x * zoom).truncatingRemainder(dividingBy: step))
        let startY = -((scroll.y * zoom).truncatingRemainder(dividingBy: step))
        let dot: CGFloat = max(1, min(2, zoom * 1.3))

        var y = startY
        while y < bounds.maxY + step {
            var x = startX
            while x < bounds.maxX + step {
                CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot).fill()
                x += step
            }
            y += step
        }
    }

    private func drawSelectionChrome() {
        guard !selection.isEmpty, dragMode.isQuiet else { return }
        let selected = drawing.elements.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return }

        Theme.accent.withAlphaComponent(0.85).setStroke()

        // Per-element hint outline when several are selected.
        if selected.count > 1 {
            for e in selected {
                let r = toViewRect(e.frame.insetBy(dx: -3, dy: -3))
                let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                p.lineWidth = 1
                p.setLineDash([3, 3], count: 2, phase: 0)
                p.stroke()
            }
        }

        guard let box = selectionBounds else { return }
        let r = toViewRect(box.insetBy(dx: -6, dy: -6))
        let outline = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        outline.lineWidth = 1.5
        outline.stroke()

        for p in handlePositions() {
            let hr = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2,
                            width: handleSize, height: handleSize)
            Theme.canvasBG.setFill()
            let knob = NSBezierPath(roundedRect: hr, xRadius: 2.5, yRadius: 2.5)
            knob.fill()
            Theme.accent.setStroke()
            knob.lineWidth = 1.5
            knob.stroke()
        }
    }

    var selectionBounds: CGRect? {
        let selected = drawing.elements.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        return selected.dropFirst().reduce(selected[0].frame) { $0.union($1.frame) }
    }

    /// Handle centres in view space. Two endpoints for a straight segment,
    /// otherwise the eight box handles.
    private func handlePositions() -> [CGPoint] {
        if let e = soleSelectedEndpointElement {
            let o = CGPoint(x: e.x, y: e.y)
            return e.points.map { toView(CGPoint(x: $0.x + o.x, y: $0.y + o.y)) }
        }
        guard let box = selectionBounds else { return [] }
        let r = toViewRect(box.insetBy(dx: -6, dy: -6))
        return [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.minX, y: r.midY)
        ]
    }

    private var soleSelectedEndpointElement: DrawElement? {
        guard selection.count == 1,
              let e = drawing.elements.first(where: { selection.contains($0.id) }),
              e.kind == .line || e.kind == .arrow,
              e.points.count == 2 else { return nil }
        return e
    }

    // MARK: - Undo

    func pushUndo() {
        undoStack.append(drawing.elements)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(drawing.elements)
        drawing.elements = prev
        selection = selection.filter { id in drawing.elements.contains { $0.id == id } }
        commit()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing.elements)
        drawing.elements = next
        selection = selection.filter { id in drawing.elements.contains { $0.id == id } }
        commit()
    }

    private func commit() {
        needsDisplay = true
        delegate?.canvasDidChange(self)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let scenePoint = toScene(viewPoint)
        dragStartScene = scenePoint

        if textEditor != nil { endTextEditing(commit: true) }

        if spaceHeld || tool == .hand || event.modifierFlags.contains(.option) && tool == .select {
            dragMode = .panning
            return
        }

        switch tool {
        case .eraser:
            dragMode = .creating   // reuse the drag loop; erase happens in mouseDragged
            pushUndo()
            eraseAt(scenePoint)

        case .select:
            if event.clickCount == 2, let hit = topElement(at: scenePoint) {
                if hit.kind == .text {
                    selection = [hit.id]
                    beginTextEditing(hit)
                    return
                }
            }
            // Handles take priority over element hits.
            if !selection.isEmpty, let h = handleIndex(at: viewPoint) {
                pushUndo()
                dragOriginals = currentSelectionSnapshot()
                dragMode = soleSelectedEndpointElement != nil ? .endpoint(index: h) : .resizing(handle: h)
                return
            }
            if let hit = topElement(at: scenePoint) {
                if event.modifierFlags.contains(.shift) {
                    if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                } else if !selection.contains(hit.id) {
                    selection = [hit.id]
                }
                pushUndo()
                dragOriginals = currentSelectionSnapshot()
                dragMode = .moving
            } else {
                if !event.modifierFlags.contains(.shift) { selection.removeAll() }
                marqueeRect = CGRect(origin: scenePoint, size: .zero)
                dragMode = .marquee
            }

        case .text:
            pushUndo()
            if let hit = topElement(at: scenePoint), hit.kind == .text {
                beginTextEditing(hit)
            } else {
                var e = DrawElement(kind: .text)
                style.applied(to: &e)
                e.x = scenePoint.x
                e.y = scenePoint.y - style.fontSize * 0.6
                e.w = 10
                e.h = style.fontSize * 1.3
                drawing.elements.append(e)
                beginTextEditing(e)
            }
            dragMode = .none

        case .hand:
            dragMode = .panning

        case .rectangle, .diamond, .ellipse, .arrow, .line, .freedraw:
            guard let kind = tool.elementKind else { return }
            pushUndo()
            var e = DrawElement(kind: kind)
            style.applied(to: &e)
            e.x = scenePoint.x
            e.y = scenePoint.y
            if e.isPath {
                e.points = [.zero, .zero]
                if kind == .freedraw { e.points = [.zero] }
            }
            drawing.elements.append(e)
            liveElementID = e.id
            selection = []
            dragMode = .creating
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let scenePoint = toScene(viewPoint)
        let shift = event.modifierFlags.contains(.shift)

        switch dragMode {
        case .panning:
            scroll.x -= event.deltaX / zoom
            scroll.y -= event.deltaY / zoom
            needsDisplay = true

        case .creating:
            if tool == .eraser {
                eraseAt(scenePoint)
                return
            }
            guard let id = liveElementID,
                  let i = drawing.elements.firstIndex(where: { $0.id == id }) else { return }
            var e = drawing.elements[i]

            switch e.kind {
            case .freedraw:
                let local = CGPoint(x: scenePoint.x - e.x, y: scenePoint.y - e.y)
                if let last = e.points.last, hypot(local.x - last.x, local.y - last.y) < 1.2 / zoom {
                    return
                }
                e.points.append(local)
                let xs = e.points.map(\.x), ys = e.points.map(\.y)
                e.w = (xs.max() ?? 0) - min(0, xs.min() ?? 0)
                e.h = (ys.max() ?? 0) - min(0, ys.min() ?? 0)

            case .line, .arrow:
                var end = CGPoint(x: scenePoint.x - e.x, y: scenePoint.y - e.y)
                if shift {
                    // Snap to 15° increments.
                    let a = atan2(end.y, end.x)
                    let snapped = (a / (.pi / 12)).rounded() * (.pi / 12)
                    let len = hypot(end.x, end.y)
                    end = CGPoint(x: cos(snapped) * len, y: sin(snapped) * len)
                }
                e.points = [.zero, end]
                e.w = end.x
                e.h = end.y

            default:
                var w = scenePoint.x - dragStartScene.x
                var h = scenePoint.y - dragStartScene.y
                if shift {
                    let side = max(abs(w), abs(h))
                    w = side * (w < 0 ? -1 : 1)
                    h = side * (h < 0 ? -1 : 1)
                }
                e.w = w
                e.h = h
            }
            e.version += 1
            drawing.elements[i] = e
            needsDisplay = true

        case .moving:
            var dx = scenePoint.x - dragStartScene.x
            var dy = scenePoint.y - dragStartScene.y
            if shift {
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            for (id, original) in dragOriginals {
                guard let i = drawing.elements.firstIndex(where: { $0.id == id }) else { continue }
                drawing.elements[i].x = original.x + dx
                drawing.elements[i].y = original.y + dy
            }
            needsDisplay = true

        case .resizing(let handle):
            resize(handle: handle, to: scenePoint, uniform: shift)

        case .endpoint(let index):
            guard let id = selection.first,
                  let i = drawing.elements.firstIndex(where: { $0.id == id }),
                  drawing.elements[i].points.indices.contains(index) else { return }
            var e = drawing.elements[i]
            var local = CGPoint(x: scenePoint.x - e.x, y: scenePoint.y - e.y)
            if shift {
                let other = e.points[1 - index]
                let a = atan2(local.y - other.y, local.x - other.x)
                let snapped = (a / (.pi / 12)).rounded() * (.pi / 12)
                let len = hypot(local.x - other.x, local.y - other.y)
                local = CGPoint(x: other.x + cos(snapped) * len, y: other.y + sin(snapped) * len)
            }
            e.points[index] = local
            // Re-normalise so origin stays at points[0].
            let shiftX = e.points[0].x, shiftY = e.points[0].y
            e.x += shiftX; e.y += shiftY
            e.points = e.points.map { CGPoint(x: $0.x - shiftX, y: $0.y - shiftY) }
            e.w = e.points[1].x; e.h = e.points[1].y
            e.version += 1
            drawing.elements[i] = e
            needsDisplay = true

        case .marquee:
            marqueeRect = CGRect(x: min(dragStartScene.x, scenePoint.x),
                                 y: min(dragStartScene.y, scenePoint.y),
                                 width: abs(scenePoint.x - dragStartScene.x),
                                 height: abs(scenePoint.y - dragStartScene.y))
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .marquee:
            if let m = marqueeRect {
                let hits = drawing.elements.filter { m.intersects($0.frame) || m.contains($0.frame) }
                selection.formUnion(hits.map(\.id))
            }
            marqueeRect = nil

        case .creating:
            if tool == .eraser {
                hoverEraseIDs.removeAll()
                commit()
                break
            }
            if let id = liveElementID,
               let i = drawing.elements.firstIndex(where: { $0.id == id }) {
                let e = drawing.elements[i]
                let tooSmall: Bool
                if e.kind == .freedraw {
                    tooSmall = e.points.count < 2
                } else {
                    tooSmall = abs(e.w) < 3 && abs(e.h) < 3
                }
                if tooSmall {
                    // A click with a shape tool: drop a default-sized shape instead
                    // of leaving a speck behind.
                    if e.kind == .freedraw || e.isPath {
                        drawing.elements.remove(at: i)
                        undoStack.removeLast()
                    } else {
                        drawing.elements[i].w = 140
                        drawing.elements[i].h = 90
                        selection = [id]
                    }
                } else {
                    selection = [id]
                }
            }
            liveElementID = nil
            commit()
            delegate?.canvasDidFinishCreating(self)

        case .moving, .resizing, .endpoint:
            dragOriginals.removeAll()
            commit()

        case .panning, .none:
            break
        }
        dragMode = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let anchor = convert(event.locationInWindow, from: nil)
            let factor = 1 + event.scrollingDeltaY * 0.01
            setZoom(zoom * factor, anchor: anchor)
            return
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        scroll.x -= event.scrollingDeltaX * scale / zoom
        scroll.y -= event.scrollingDeltaY * scale / zoom
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchor: anchor)
    }

    // MARK: - Hit testing

    private func topElement(at p: CGPoint) -> DrawElement? {
        let tolerance = 10 / zoom
        for e in drawing.elements.reversed() where e.hitTest(p, tolerance: tolerance) {
            return e
        }
        return nil
    }

    private func handleIndex(at viewPoint: CGPoint) -> Int? {
        for (i, h) in handlePositions().enumerated() {
            if abs(h.x - viewPoint.x) <= handleSize && abs(h.y - viewPoint.y) <= handleSize {
                return i
            }
        }
        return nil
    }

    private func currentSelectionSnapshot() -> [UUID: DrawElement] {
        var map: [UUID: DrawElement] = [:]
        for e in drawing.elements where selection.contains(e.id) { map[e.id] = e }
        return map
    }

    private func eraseAt(_ p: CGPoint) {
        let tolerance = 12 / zoom
        for e in drawing.elements.reversed() where e.hitTest(p, tolerance: tolerance) {
            hoverEraseIDs.insert(e.id)
        }
        if !hoverEraseIDs.isEmpty {
            drawing.elements.removeAll { hoverEraseIDs.contains($0.id) }
            needsDisplay = true
        }
    }

    // MARK: - Resize

    private func resize(handle: Int, to p: CGPoint, uniform: Bool) {
        guard let original = dragOriginals.values.first,
              !dragOriginals.isEmpty else { return }
        let box = dragOriginals.values.dropFirst().reduce(original.frame) { $0.union($1.frame) }
        guard box.width > 0.001, box.height > 0.001 else { return }

        var newBox = box
        // Handles run clockwise from top-left.
        switch handle {
        case 0: newBox = CGRect(x: p.x, y: p.y, width: box.maxX - p.x, height: box.maxY - p.y)
        case 1: newBox = CGRect(x: box.minX, y: p.y, width: box.width, height: box.maxY - p.y)
        case 2: newBox = CGRect(x: box.minX, y: p.y, width: p.x - box.minX, height: box.maxY - p.y)
        case 3: newBox = CGRect(x: box.minX, y: box.minY, width: p.x - box.minX, height: box.height)
        case 4: newBox = CGRect(x: box.minX, y: box.minY, width: p.x - box.minX, height: p.y - box.minY)
        case 5: newBox = CGRect(x: box.minX, y: box.minY, width: box.width, height: p.y - box.minY)
        case 6: newBox = CGRect(x: p.x, y: box.minY, width: box.maxX - p.x, height: p.y - box.minY)
        case 7: newBox = CGRect(x: p.x, y: box.minY, width: box.maxX - p.x, height: box.height)
        default: return
        }

        var sx = newBox.width / box.width
        var sy = newBox.height / box.height
        if uniform {
            let s = max(abs(sx), abs(sy))
            sx = s * (sx < 0 ? -1 : 1)
            sy = s * (sy < 0 ? -1 : 1)
        }
        guard abs(sx) > 0.01, abs(sy) > 0.01 else { return }

        let anchorX = newBox.minX, anchorY = newBox.minY

        for (id, orig) in dragOriginals {
            guard let i = drawing.elements.firstIndex(where: { $0.id == id }) else { continue }
            var e = orig
            e.x = anchorX + (orig.x - box.minX) * sx
            e.y = anchorY + (orig.y - box.minY) * sy
            e.w = orig.w * sx
            e.h = orig.h * sy
            if e.isPath {
                e.points = orig.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            }
            if e.kind == .text {
                e.fontSize = max(6, orig.fontSize * min(abs(sx), abs(sy)))
                let size = ElementPainter.measuredSize(for: e, isDark: isDark)
                e.w = size.width
                e.h = size.height
            }
            e.version += 1
            drawing.elements[i] = e
        }
        needsDisplay = true
    }

    // MARK: - Text editing

    private func beginTextEditing(_ element: DrawElement) {
        endTextEditing(commit: true)
        guard let i = drawing.elements.firstIndex(where: { $0.id == element.id }) else { return }
        let e = drawing.elements[i]
        editingElementID = e.id

        let frame = editorFrame(for: e)
        let tv = NSTextView(frame: frame)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.font = scaledFont(for: e)
        tv.textColor = Palette.resolveStroke(e.strokeColor, isDark: isDark)
        tv.insertionPointColor = Theme.accent
        tv.string = e.text
        tv.delegate = self
        tv.alignment = [.left, .center, .right][max(0, min(2, e.textAlign))]

        addSubview(tv)
        textEditor = tv
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: e.text.count, length: 0))
        needsDisplay = true
    }

    private func scaledFont(for e: DrawElement) -> NSFont {
        var scaled = e
        scaled.fontSize = e.fontSize * zoom
        return ElementPainter.font(for: scaled)
    }

    private func editorFrame(for e: DrawElement) -> CGRect {
        let origin = toView(CGPoint(x: e.frame.minX, y: e.frame.minY))
        let size = ElementPainter.measuredSize(for: e, isDark: isDark)
        return CGRect(x: origin.x, y: origin.y,
                      width: max(size.width, 40) * zoom + 8,
                      height: max(size.height, e.fontSize * 1.2) * zoom + 4)
    }

    func endTextEditing(commit shouldCommit: Bool) {
        guard let tv = textEditor, let id = editingElementID else { return }
        let text = tv.string
        tv.removeFromSuperview()
        textEditor = nil
        editingElementID = nil

        guard let i = drawing.elements.firstIndex(where: { $0.id == id }) else { return }
        if !shouldCommit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drawing.elements.remove(at: i)
            selection.remove(id)
        } else {
            drawing.elements[i].text = text
            let size = ElementPainter.measuredSize(for: drawing.elements[i], isDark: isDark)
            drawing.elements[i].w = size.width
            drawing.elements[i].h = size.height
            selection = [id]
        }
        commit()
        delegate?.canvasDidFinishCreating(self)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textEditor, let id = editingElementID,
              let i = drawing.elements.firstIndex(where: { $0.id == id }) else { return }
        drawing.elements[i].text = tv.string
        let size = ElementPainter.measuredSize(for: drawing.elements[i], isDark: isDark)
        drawing.elements[i].w = size.width
        drawing.elements[i].h = size.height
        tv.frame = editorFrame(for: drawing.elements[i])
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: true)
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    var isEditingText: Bool { textEditor != nil }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if event.keyCode == 49 {   // space — temporary pan
            spaceHeld = true
            updateCursor()
            return
        }

        if cmd {
            switch chars.lowercased() {
            case "z": shift ? redo() : undo(); return
            case "a":
                selection = Set(drawing.elements.map(\.id))
                return
            case "d": duplicateSelection(); return
            case "c": copySelection(); return
            case "v": pasteClipboard(); return
            case "x": copySelection(); deleteSelection(); return
            case "]": bringForward(); return
            case "[": sendBackward(); return
            default: break
            }
        }

        switch event.keyCode {
        case 51, 117:   // delete / forward delete
            deleteSelection()
            return
        case 53:        // escape
            selection.removeAll()
            return
        case 123, 124, 125, 126:   // arrows
            nudge(keyCode: event.keyCode, big: shift)
            return
        default: break
        }

        // Tool shortcuts.
        if let t = CanvasTool.allCases.first(where: { $0.key == chars }) {
            tool = t
            delegate?.canvasDidChangeSelection(self)
            return
        }
        let letterMap: [String: CanvasTool] = [
            "v": .select, "h": .hand, "r": .rectangle, "d": .diamond, "o": .ellipse,
            "a": .arrow, "l": .line, "p": .freedraw, "t": .text, "e": .eraser
        ]
        if let t = letterMap[chars.lowercased()] {
            tool = t
            delegate?.canvasDidChangeSelection(self)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            updateCursor()
            return
        }
        super.keyUp(with: event)
    }

    private func nudge(keyCode: UInt16, big: Bool) {
        guard !selection.isEmpty else { return }
        let d: CGFloat = big ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch keyCode {
        case 123: dx = -d
        case 124: dx = d
        case 125: dy = d
        case 126: dy = -d
        default: break
        }
        pushUndo()
        for i in drawing.elements.indices where selection.contains(drawing.elements[i].id) {
            drawing.elements[i].x += dx
            drawing.elements[i].y += dy
        }
        commit()
    }

    // MARK: - Editing commands

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        pushUndo()
        drawing.elements.removeAll { selection.contains($0.id) }
        selection.removeAll()
        commit()
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        pushUndo()
        var newIDs: Set<UUID> = []
        for e in drawing.elements where selection.contains(e.id) {
            var copy = e
            copy.id = UUID()
            copy.x += 16
            copy.y += 16
            copy.seed = UInt32.random(in: 1...100_000)
            drawing.elements.append(copy)
            newIDs.insert(copy.id)
        }
        selection = newIDs
        commit()
    }

    func selectAll() { selection = Set(drawing.elements.map(\.id)) }

    func bringForward() {
        guard !selection.isEmpty else { return }
        pushUndo()
        var elements = drawing.elements
        for i in stride(from: elements.count - 2, through: 0, by: -1)
        where selection.contains(elements[i].id) && !selection.contains(elements[i + 1].id) {
            elements.swapAt(i, i + 1)
        }
        drawing.elements = elements
        commit()
    }

    func sendBackward() {
        guard !selection.isEmpty else { return }
        pushUndo()
        var elements = drawing.elements
        for i in 1..<max(elements.count, 1)
        where selection.contains(elements[i].id) && !selection.contains(elements[i - 1].id) {
            elements.swapAt(i, i - 1)
        }
        drawing.elements = elements
        commit()
    }

    func applyStyleToSelection(_ newStyle: DrawStyle) {
        style = newStyle
        guard !selection.isEmpty else { return }
        pushUndo()
        for i in drawing.elements.indices where selection.contains(drawing.elements[i].id) {
            var e = drawing.elements[i]
            newStyle.applied(to: &e)
            if e.kind == .text {
                let size = ElementPainter.measuredSize(for: e, isDark: isDark)
                e.w = size.width; e.h = size.height
            }
            drawing.elements[i] = e
        }
        commit()
    }

    // MARK: - Clipboard

    private static let pasteboardType = NSPasteboard.PasteboardType("com.natesnotes.elements")

    func copySelection() {
        let picked = drawing.elements.filter { selection.contains($0.id) }
        guard !picked.isEmpty, let data = try? JSONEncoder().encode(picked) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: CanvasView.pasteboardType)
    }

    func pasteClipboard() {
        guard let data = NSPasteboard.general.data(forType: CanvasView.pasteboardType),
              let picked = try? JSONDecoder().decode([DrawElement].self, from: data),
              !picked.isEmpty else { return }
        pushUndo()
        var newIDs: Set<UUID> = []
        for e in picked {
            var copy = e
            copy.id = UUID()
            copy.x += 20
            copy.y += 20
            drawing.elements.append(copy)
            newIDs.insert(copy.id)
        }
        selection = newIDs
        commit()
    }

    // MARK: - Cursor

    private func updateCursor() {
        let cursor: NSCursor
        if spaceHeld || tool == .hand {
            cursor = .openHand
        } else if tool == .text {
            cursor = .iBeam
        } else if tool == .select {
            cursor = .arrow
        } else {
            cursor = .crosshair
        }
        cursor.set()
    }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor
        if spaceHeld || tool == .hand { cursor = .openHand }
        else if tool == .text { cursor = .iBeam }
        else if tool == .select { cursor = .arrow }
        else { cursor = .crosshair }
        addCursorRect(bounds, cursor: cursor)
    }
}
