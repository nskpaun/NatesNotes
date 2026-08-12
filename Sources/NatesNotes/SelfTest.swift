import AppKit
import SyncKit
import SwiftUI

/// Offscreen render pass used to eyeball the editor and canvas without a display.
/// Run with:  NatesNotes.app/Contents/MacOS/NatesNotes --render-samples <dir>
enum SelfTest {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--test-canvas") {
            testCanvas()
            return true
        }
        if args.contains("--test-sync-mapping") {
            testSyncMapping()
            return true
        }
        if args.contains("--test-store") {
            MainActor.assumeIsolated { testStoreOrdering() }
            return true
        }
        if let flag = args.firstIndex(of: "--render-app") {
            let dir = args.count > flag + 1 ? args[flag + 1] : NSTemporaryDirectory()
            MainActor.assumeIsolated { renderApp(to: dir, locked: args.contains("--locked")) }
            return true
        }
        guard let flag = args.firstIndex(of: "--render-samples") else { return false }
        let dir = args.count > flag + 1 ? args[flag + 1] : NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let dark = args.contains("--dark")
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            renderCanvasSample(to: dir, isDark: dark)
            renderEditorSample(to: dir, isDark: dark)
        }
        print("rendered \(dark ? "dark" : "light") samples to \(dir)")
        return true
    }

    // MARK: - Canvas interaction test

    /// Drives the canvas with synthesised mouse events so the direct-manipulation
    /// paths (create, select, move, resize, undo, delete) actually get exercised.
    private static func testCanvas() {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas

        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }

        // The window is bottom-left origin; the canvas is flipped.
        func event(_ type: NSEvent.EventType, _ viewPoint: CGPoint) -> NSEvent {
            let inWindow = canvas.convert(viewPoint, to: nil)
            return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: 1)!
        }
        func drag(from a: CGPoint, to b: CGPoint, steps: Int = 6) {
            canvas.mouseDown(with: event(.leftMouseDown, a))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                canvas.mouseDragged(with: event(.leftMouseDragged,
                                                CGPoint(x: a.x + (b.x - a.x) * t,
                                                        y: a.y + (b.y - a.y) * t)))
            }
            canvas.mouseUp(with: event(.leftMouseUp, b))
        }

        // 1. Draw a rectangle.
        canvas.tool = .rectangle
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 220))
        check("rectangle created", canvas.drawing.elements.count == 1,
              "count=\(canvas.drawing.elements.count)")
        let rect = canvas.drawing.elements.first
        check("rectangle geometry", rect.map { abs($0.w - 200) < 2 && abs($0.h - 120) < 2 } ?? false,
              "w=\(rect?.w ?? -1) h=\(rect?.h ?? -1)")
        check("auto-selected after draw", canvas.selection.count == 1)

        // 2. Freehand stroke.
        canvas.tool = .freedraw
        drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 520, y: 380), steps: 20)
        check("freehand created", canvas.drawing.elements.count == 2,
              "count=\(canvas.drawing.elements.count)")
        check("freehand collected points",
              (canvas.drawing.elements.last?.points.count ?? 0) > 3,
              "points=\(canvas.drawing.elements.last?.points.count ?? 0)")

        // 3. Select the rectangle and move it.
        canvas.tool = .select
        guard let rectID = canvas.drawing.elements.first?.id else { return }
        let before = canvas.drawing.elements[0].x
        drag(from: CGPoint(x: 110, y: 105), to: CGPoint(x: 160, y: 145))   // grab the edge
        let moved = canvas.drawing.elements.first { $0.id == rectID }
        check("rectangle moved", moved.map { abs($0.x - (before + 50)) < 2 } ?? false,
              "x \(before) → \(moved?.x ?? -1)")

        // 4. Undo returns it.
        canvas.undo()
        let undone = canvas.drawing.elements.first { $0.id == rectID }
        check("undo restored position", undone.map { abs($0.x - before) < 2 } ?? false,
              "x=\(undone?.x ?? -1)")

        // 5. Duplicate and delete.
        canvas.selection = [rectID]
        canvas.duplicateSelection()
        check("duplicate added an element", canvas.drawing.elements.count == 3,
              "count=\(canvas.drawing.elements.count)")
        canvas.deleteSelection()
        check("delete removed the duplicate", canvas.drawing.elements.count == 2,
              "count=\(canvas.drawing.elements.count)")

        // 6. Zoom keeps the scene anchored.
        canvas.setZoom(2, anchor: CGPoint(x: 400, y: 300))
        let sceneAtAnchor = canvas.toScene(CGPoint(x: 400, y: 300))
        canvas.setZoom(1, anchor: CGPoint(x: 400, y: 300))
        let sceneAfter = canvas.toScene(CGPoint(x: 400, y: 300))
        check("zoom anchor stable",
              abs(sceneAtAnchor.x - sceneAfter.x) < 0.5 && abs(sceneAtAnchor.y - sceneAfter.y) < 0.5,
              "\(sceneAtAnchor) vs \(sceneAfter)")

        // 7. Round-trip through the on-disk encoding.
        if let data = try? JSONEncoder().encode(canvas.drawing),
           let back = try? JSONDecoder().decode(Drawing.self, from: data) {
            check("drawing survives encode/decode", back.elements.count == canvas.drawing.elements.count)
        } else {
            check("drawing survives encode/decode", false, "codec threw")
        }

        print(failures == 0 ? "\nAll canvas checks passed." : "\n\(failures) check(s) FAILED.")
    }

    /// Set by `ContentView` in render mode so the harness can open the modal.
    nonisolated(unsafe) static var requestModal: (() -> Void)?

    // MARK: - Whole-UI render

    /// Renders the real SwiftUI hierarchy offscreen so the chrome can be
    /// inspected without a display or screen-recording permission.
    @MainActor private static func renderApp(to dir: String, locked: Bool) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The app's own WindowGroup window would otherwise keep writing the
        // shared Theme.mode from its own AppState. Close it first.
        NSApp.windows.forEach { $0.close() }
        UserDefaults.standard.set(locked ? AppMode.lockedIn.rawValue : AppMode.chill.rawValue,
                                  forKey: "nn.mode")
        Theme.mode = locked ? .lockedIn : .chill

        // A throwaway library so the render never touches the real notes.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nn-render-\(UUID().uuidString)", isDirectory: true)
        let store = NoteStore(root: root)
        store.notes = []
        let drawing = sampleDrawing()
        var note = Note(text: sampleNote.replacingOccurrences(
            of: "DRAWING-ID", with: drawing.id.uuidString))
        note.emoji = "🌙"
        note.drawings[drawing.id] = drawing
        store.notes = [note, Note(text: "# Ideas Vault\n\nThings worth keeping."),
                       Note(text: "# Writing\n\nDrafts in progress."),
                       Note(text: "# Journal\n\nToday was long.")]
        store.selectedID = note.id

        let sync = SyncController(notes: store, root: root.appendingPathComponent("sync"))
        let content = ContentView(store: store, sync: sync)

        let size = CGSize(width: 1240, height: 760)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBG
        window.contentView = hosting
        // Park it far offscreen: SwiftUI needs a real window to lay out, but the
        // user should never see it.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first layout and entrance animations.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if CommandLine.arguments.contains("--modal") {
            SelfTest.requestModal?()
            RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        }
        // Re-assert and repaint, so the capture can't catch a stale accent.
        Theme.mode = locked ? .lockedIn : .chill
        MarkdownTextView.focused?.restyle()
        hosting.layoutSubtreeIfNeeded()
        hosting.setNeedsDisplay(hosting.bounds)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let modal = CommandLine.arguments.contains("--modal") ? "-modal" : ""
            let name = "app-\(locked ? "locked" : "chill")\(modal).png"
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
        print("rendered \(locked ? "locked" : "chill") app UI to \(dir)")
    }

    private static let sampleNote = """
    # Midnight Thoughts

    > In the quiet, the signal gets louder.

    A space for deep thinking and expression — local first, distraction free, \
    beautifully simple.

    ## Principles

    - [x] Clarity over cleverness
    - [x] Depth over noise
    - [ ] Progress over perfection

    ## The loop

    ![](drawing://DRAWING-ID)

    Every idea starts as a **spark**, gets *refined*, and eventually ships. \
    Type `/` for blocks, `/draw` for a sketch.

    ---

    ## A small system

    ```
    const system = {
      capture: 'Anything worth remembering',
      connect: 'Find the threads',
      repeat: true
    }
    ```
    """

    // MARK: - Sidebar ordering

    /// Typing used to bump `updated`, which re-sorted the sidebar on every
    /// keystroke — the note being edited jumped to the top and the whole list
    /// flickered. These checks pin the fix.
    @MainActor private static func testStoreOrdering() {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nn-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NoteStore(root: root)
        store.notes = []
        let a = Note(text: "# Alpha"), b = Note(text: "# Beta"), c = Note(text: "# Gamma")
        store.notes = [a, b, c]
        store.selectedID = c.id

        let orderBefore = store.orderedNotes.map(\.id)
        check("order established", orderBefore.count == 3)

        // Type 30 characters into whichever note is last in the list.
        let target = orderBefore.last!
        var text = ""
        for i in 0..<30 {
            text += "\(i % 10)"
            store.updateText("# Typing\n\n" + text, for: target)
        }

        let orderAfter = store.orderedNotes.map(\.id)
        check("typing does not reorder the sidebar", orderBefore == orderAfter,
              orderBefore == orderAfter ? "" : "list reshuffled mid-edit")
        check("the edit still landed",
              store.notes.first { $0.id == target }?.text.contains("Typing") == true)

        // Switching notes is an explicit act, so the list may settle then.
        store.selectedID = orderBefore.first
        let settled = store.orderedNotes.map(\.id)
        check("recency applies once you move on", settled.first == target,
              "most-recently-edited rose to the top")

        // Structural changes reorder immediately.
        let fresh = store.newNote(text: "# Fresh")
        check("a new note appears at the top", store.orderedNotes.first?.id == fresh.id)

        store.togglePin(target)
        check("pinned notes lead", store.orderedNotes.first?.id == target)

        print(failures == 0 ? "\nAll store ordering checks passed."
                            : "\n\(failures) check(s) FAILED.")
    }

    // MARK: - Sync mapping and merge

    /// `NoteDocument` and `NoteMerge` live in the app target, which XCTest can't
    /// import, so they're exercised here instead of going unverified.
    private static func testSyncMapping() {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }

        // Canonical encoding must be deterministic and round-trip cleanly.
        var note = Note(text: "# Title\n\nBody **bold**")
        note.pinned = true
        note.emoji = "🚀"
        let document = NoteDocument(note: note)
        let encodedOnce = document.canonicalData()
        let encodedTwice = NoteDocument(note: note).canonicalData()
        check("canonical encoding is byte-stable", encodedOnce == encodedTwice)

        let decoded = NoteDocument(data: encodedOnce)
        check("round-trips", decoded?.body == note.text && decoded?.pinned == true
              && decoded?.emoji == "🚀")
        check("derives title", decoded?.title == "Title", decoded?.title ?? "nil")

        // A field from a newer client must survive this client rewriting it.
        var withFuture = try! CanonicalJSON.decode(encodedOnce).objectValue!
        withFuture["futureField"] = .string("keep me")
        let forwardCompatible = NoteDocument(data: CanonicalJSON.encode(.object(withFuture)))
        let rewritten = forwardCompatible?.canonicalData() ?? Data()
        let reparsed = (try? CanonicalJSON.decode(rewritten))?["futureField"]?.stringValue
        check("preserves unknown fields", reparsed == "keep me", reparsed ?? "nil")

        // Three-way merge.
        let base = NoteDocument(note: Note(text: "shared base"))
        var localNote = Note(id: base.id, text: "shared base")
        var remoteNote = Note(id: base.id, text: "shared base")

        // Only the server moved.
        remoteNote.text = "changed remotely"
        var outcome = NoteMerge.merge(base: base,
                                      local: NoteDocument(note: localNote),
                                      remote: NoteDocument(note: remoteNote))
        if case .useRemote(let merged) = outcome {
            check("remote-only edit is accepted", merged.body == "changed remotely")
        } else {
            check("remote-only edit is accepted", false, "\(outcome)")
        }

        // Only this device moved.
        localNote.text = "changed locally"
        remoteNote.text = "shared base"
        outcome = NoteMerge.merge(base: base,
                                  local: NoteDocument(note: localNote),
                                  remote: NoteDocument(note: remoteNote))
        if case .merged(let merged) = outcome {
            check("local-only edit is kept", merged.body == "changed locally")
        } else {
            check("local-only edit is kept", false, "\(outcome)")
        }

        // Different fields on each side merge without asking.
        localNote.text = "shared base"
        localNote.pinned = true
        remoteNote.text = "changed remotely"
        remoteNote.pinned = false
        outcome = NoteMerge.merge(base: base,
                                  local: NoteDocument(note: localNote),
                                  remote: NoteDocument(note: remoteNote))
        if case .useRemote(let merged) = outcome {
            check("field-wise merge keeps both changes",
                  merged.body == "changed remotely" && merged.pinned == true)
        } else {
            check("field-wise merge keeps both changes", false, "\(outcome)")
        }

        // Same field, two different edits — must not silently pick one.
        localNote.text = "mine"
        remoteNote.text = "theirs"
        outcome = NoteMerge.merge(base: base,
                                  local: NoteDocument(note: localNote),
                                  remote: NoteDocument(note: remoteNote))
        if case .conflict(let localDoc, let remoteDoc) = outcome {
            check("divergent body is a conflict",
                  localDoc.body == "mine" && remoteDoc.body == "theirs")
            let copy = NoteMerge.conflictCopy(of: remoteDoc, source: localDoc.id)
            check("conflict copy retains the other version",
                  copy.text.contains("theirs") && copy.id != remoteDoc.id)
            // One copy per record: detecting the same conflict twice must land
            // on the same note rather than minting a second one.
            check("conflict copy id is stable per record",
                  NoteMerge.conflictCopy(of: remoteDoc, source: localDoc.id).id == copy.id)
            check("an untouched copy is refreshable",
                  NoteMerge.isUntouchedConflictCopy(copy))
            var edited = copy
            edited.text = "user rewrote this"
            check("an edited copy is left alone",
                  !NoteMerge.isUntouchedConflictCopy(edited))
        } else {
            check("divergent body is a conflict", false, "\(outcome)")
        }

        // With no common base we can't tell who moved, so differing content is
        // treated as a conflict rather than guessed at.
        outcome = NoteMerge.merge(base: nil,
                                  local: NoteDocument(note: localNote),
                                  remote: NoteDocument(note: remoteNote))
        if case .conflict = outcome {
            check("no base means conflict, not a guess", true)
        } else {
            check("no base means conflict, not a guess", false, "\(outcome)")
        }

        // Drawings: viewport state must not affect the synced bytes.
        var drawing = SelfTest.sampleDrawing()
        let noteId = UUID()
        let before = DrawingDocument(drawing: drawing, noteId: noteId,
                                     modifiedAt: Date(timeIntervalSince1970: 0)).canonicalData()
        drawing.scrollX = 900; drawing.scrollY = -120; drawing.zoom = 2.5
        let after = DrawingDocument(drawing: drawing, noteId: noteId,
                                    modifiedAt: Date(timeIntervalSince1970: 0)).canonicalData()
        check("panning a drawing is not a document change", before == after)

        let roundTripped = DrawingDocument(data: after)
        check("drawing round-trips its elements",
              roundTripped?.elements.count == drawing.elements.count,
              "\(roundTripped?.elements.count ?? -1) vs \(drawing.elements.count)")

        print(failures == 0 ? "\nAll sync mapping checks passed." : "\n\(failures) check(s) FAILED.")
    }

    // MARK: - Sample content

    static func sampleDrawing() -> Drawing {
        var d = Drawing()

        var box = DrawElement(kind: .rectangle)
        box.x = 60; box.y = 60; box.w = 220; box.h = 120
        box.fillColor = "#A5D8FF"; box.fillStyle = .hachure
        box.strokeWidth = 2; box.roughness = 1.4; box.seed = 4242
        d.elements.append(box)

        var label = DrawElement(kind: .text)
        label.x = 96; label.y = 100; label.text = "Client"
        label.fontSize = 22; label.seed = 11
        label.w = ElementPainter.measuredSize(for: label, isDark: false).width
        label.h = ElementPainter.measuredSize(for: label, isDark: false).height
        d.elements.append(label)

        var arrow = DrawElement(kind: .arrow)
        arrow.x = 290; arrow.y = 120
        arrow.points = [.zero, CGPoint(x: 150, y: 0)]
        arrow.w = 150; arrow.strokeWidth = 2; arrow.seed = 777
        d.elements.append(arrow)

        var circle = DrawElement(kind: .ellipse)
        circle.x = 460; circle.y = 55; circle.w = 190; circle.h = 130
        circle.strokeColor = "#2F9E44"; circle.fillColor = "#B2F2BB"
        circle.fillStyle = .crossHatch; circle.seed = 909
        d.elements.append(circle)

        var diamond = DrawElement(kind: .diamond)
        diamond.x = 200; diamond.y = 250; diamond.w = 200; diamond.h = 130
        diamond.strokeColor = "#E03131"; diamond.fillColor = "#FFC9C9"
        diamond.fillStyle = .solid; diamond.strokeStyle = .dashed; diamond.seed = 313
        d.elements.append(diamond)

        var ink = DrawElement(kind: .freedraw)
        ink.x = 470; ink.y = 250
        ink.strokeColor = "#9C36B5"; ink.strokeWidth = 3
        var pts: [CGPoint] = []
        for i in 0...60 {
            let t = CGFloat(i) / 6
            pts.append(CGPoint(x: t * 18, y: sin(t) * 34 + 60))
        }
        ink.points = pts
        ink.w = 180; ink.h = 120
        d.elements.append(ink)

        var line = DrawElement(kind: .line)
        line.x = 60; line.y = 420
        line.points = [.zero, CGPoint(x: 600, y: 0)]
        line.w = 600; line.strokeStyle = .dotted; line.strokeWidth = 2; line.seed = 55
        d.elements.append(line)

        return d
    }

    // MARK: - Renders

    private static func renderCanvasSample(to dir: String, isDark: Bool) {
        let drawing = sampleDrawing()
        guard let image = ElementPainter.image(for: drawing,
                                               maxSize: CGSize(width: 900, height: 700),
                                               isDark: isDark, scale: 2, padding: 24,
                                               background: Theme.canvasBG),
              let data = png(from: image) else { return }
        let name = isDark ? "canvas-dark.png" : "canvas.png"
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private static func renderEditorSample(to dir: String, isDark: Bool) {
        let width: CGFloat = 820
        let textView = MarkdownTextView.make()
        let stub = StubDelegate()
        textView.mdDelegate = stub
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 4000)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 4000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 4000))
        host.addSubview(textView)
        window.contentView = host

        textView.string = sampleMarkdown
        // Park the caret at the top so we render the resting state, with every
        // syntax marker collapsed rather than revealed on the caret's line.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.layoutSubtreeIfNeeded()
        textView.restyle()

        guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        let height = ceil(used.height) + 90
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.layoutSubtreeIfNeeded()
        lm.ensureLayout(for: container)

        if CommandLine.arguments.contains("--debug") {
            let storage = textView.textStorage!
            storage.enumerateAttribute(.lineDecoration,
                                       in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let frag = lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
                let bound = lm.boundingRect(forGlyphRange: g, in: container)
                let snippet = (storage.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\n", with: "⏎").prefix(28)
                print("deco chars=\(range) glyphs=\(g) fragY=\(Int(frag.minY)) boundY=\(Int(bound.minY)) :: \(snippet)")
            }
            let all = NSRange(location: 0, length: lm.numberOfGlyphs)
            lm.enumerateLineFragments(forGlyphRange: all) { rect, used, _, glyphRange, _ in
                let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                let snippet = (storage.string as NSString).substring(with: chars)
                    .replacingOccurrences(of: "\n", with: "⏎").prefix(30)
                print("frag y=\(Int(rect.minY))..\(Int(rect.maxY)) usedY=\(Int(used.minY)) chars=\(chars) :: \(snippet)")
            }

            let ns = storage.string as NSString
            let lastLine = ns.paragraphRange(for: NSRange(location: ns.length - 2, length: 0))
            storage.enumerateAttributes(in: lastLine) { attrs, r, _ in
                let hidden = attrs[.hiddenMD] != nil
                print("last-line run \(r) hidden=\(hidden) :: '\(ns.substring(with: r))'")
            }
        }

        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return }
        // Paint the page colour first; the view itself is transparent.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            Theme.canvasBG.setFill()
            textView.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let name = isDark ? "editor-dark.png" : "editor.png"
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Support

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class StubDelegate: MarkdownTextViewDelegate {
        let drawing = SelfTest.sampleDrawing()
        func markdownTextViewDidEdit(_ view: MarkdownTextView) {}
        func markdownTextView(_ view: MarkdownTextView, didClickDrawing id: UUID, at rect: CGRect) {}
        func markdownTextViewRequestsNewDrawing(_ view: MarkdownTextView) {}
        func markdownTextView(_ view: MarkdownTextView, drawingFor id: UUID) -> Drawing? { drawing }
    }

    private static let sampleMarkdown = """
    # Design review notes

    A native macOS notebook that renders **markdown as you type** and lets you \
    sketch *hand-drawn* diagrams inside a note.

    ## What shipped

    - Live preview with `hidden` syntax markers
    - Nested bullets, quotes and dividers
    - ==Highlighted== spans and ~~struck~~ text

    1. First ordered item
    2. Second ordered item

    - [ ] Wire up the export panel
    - [x] Hand-drawn renderer
    - [ ] Ship it

    > Markers step out of the way until the caret lands on the line.

    ```
    func greet(_ name: String) -> String {
        "Hello, \\(name)"
    }
    ```

    ---

    ![](drawing://DRAWING-ID)

    Read more at [the docs](https://example.com).
    """
}
