import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var sync: SyncController
    @StateObject private var app = AppState()
    @StateObject private var canvas = CanvasController()

    /// Set by the editor when a sketch card is clicked, so the modal knows
    /// which rectangle to grow out of.
    @State private var redrawTick = 0

    private var locked: Bool { app.mode == .lockedIn }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TitleBar(store: store, app: app, sync: sync, onDraw: newSketch)

                HStack(spacing: 0) {
                    if app.sidebarVisible {
                        Sidebar(store: store, app: app)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    Group {
                        if let note = store.selected {
                            notePane(note)
                        } else {
                            EmptyState(store: store)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                StatusBar(store: store, app: app, canvas: canvas)
            }
            .background(Theme.sWindow)

            // Modal layers, above everything.
            if let open = app.openDrawing {
                DrawingModal(app: app, controller: canvas, open: open, onClose: closeSketch)
                    .zIndex(20)
            }

            if app.paletteOpen {
                CommandPalette(store: store, app: app, onNewSketch: newSketch)
                    .zIndex(30)
            }

            // The glow ring lives on top so it reads as the window's own edge.
            GlowRing(active: locked)
                .zIndex(40)
        }
        .background(Theme.sWindow)
        .animation(Motion.mode, value: app.mode)
        .onAppear {
            Theme.mode = app.mode
            // Offscreen render harness hook; no-op in normal use.
            SelfTest.requestModal = {
                guard let note = store.selected, let id = note.drawings.keys.first else { return }
                let rect = MarkdownTextView.focused?.cardRectInWindow(for: id)
                    ?? CGRect(x: 400, y: 300, width: 420, height: 200)
                openSketch(id, in: note.id, from: rect)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            // Repaint the AppKit-drawn surfaces with the new accent.
            NSApp.windows.forEach { $0.contentView?.setNeedsDisplay($0.contentView?.bounds ?? .zero) }
            redrawTick += 1
        }
        .background(KeyCatcher(app: app, store: store, onNewSketch: newSketch))
    }

    // MARK: - Note pane

    private func notePane(_ note: Note) -> some View {
        VStack(spacing: 0) {
            ConflictBanner(sync: sync, noteID: note.id)
            MarkdownEditor(
                noteID: note.id,
                text: Binding(
                    get: { store.notes.first { $0.id == note.id }?.text ?? "" },
                    set: { store.updateText($0, for: note.id) }),
                drawingProvider: { store.drawing($0, in: note.id) },
                onOpenDrawing: { id, rect in openSketch(id, in: note.id, from: rect) },
                onCreateDrawing: createSketch,
                redrawTick: redrawTick
            )
            // Switching notes crossfades and lifts, rather than cutting.
            .id(note.id)
            .transition(.opacity.combined(with: .offset(y: 10)))
        }
        .background(Theme.sPanel)
        .animation(Motion.spring, value: store.selectedID)
    }

    // MARK: - Sketch flow

    private func openSketch(_ drawingID: UUID, in noteID: UUID, from rect: CGRect) {
        let drawing = store.drawing(drawingID, in: noteID) ?? Drawing(id: drawingID)
        canvas.load(drawing)
        canvas.onChange = { updated in
            var d = updated
            d.id = drawingID
            store.setDrawing(d, for: noteID)
        }
        app.openDrawing = AppState.OpenDrawing(noteID: noteID, drawingID: drawingID,
                                               sourceRect: rect, preview: nil)
    }

    /// From the toolbar or ⇧⌘D: inserts a reference, then opens the modal.
    private func newSketch() {
        sendToResponder(#selector(MarkdownTextView.insertDrawingMD(_:)))
    }

    private func createSketch(_ insert: @escaping (UUID) -> Void) {
        guard let noteID = store.selectedID else { return }
        let drawing = Drawing()
        store.setDrawing(drawing, for: noteID)
        insert(drawing.id)
        // Give the editor a beat to lay the new card out, then grow from it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let rect = MarkdownTextView.focused?.cardRectInWindow(for: drawing.id) ?? .zero
            openSketch(drawing.id, in: noteID, from: rect)
        }
    }

    private func closeSketch() {
        guard let open = app.openDrawing else { return }
        canvas.view.endTextEditing(commit: true)
        var d = canvas.drawing
        d.id = open.drawingID
        store.setDrawing(d, for: open.noteID)
        store.flush()
        app.openDrawing = nil
        redrawTick += 1
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var app: AppState
    @ObservedObject var canvas: CanvasController

    private var locked: Bool { app.mode == .lockedIn }

    private var words: Int { store.selected?.wordCount ?? 0 }
    private var readMinutes: Int { max(1, Int(ceil(Double(words) / 220))) }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 12) {
                Text("\(words) words")
                    .contentTransition(.numericText())
                Text("·").opacity(0.4)
                Text("\(readMinutes) min read")

                Spacer()

                if let note = store.selected, note.hasDrawing {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.sAccent).frame(width: 5, height: 5)
                        Text("\(note.drawings.count) sketch\(note.drawings.count == 1 ? "" : "es")")
                    }
                    .transition(.opacity)
                }
                Text(app.mode.shortLabel)
                    .foregroundStyle(Theme.sAccent)
                    .contentTransition(.opacity)
            }
            .font(Font(Theme.mono(10.5)))
            .foregroundStyle(Theme.sTextTertiary)
            .padding(.horizontal, 16)
            .frame(height: Theme.statusBarHeight)

            LiveDivider(axis: .horizontal, active: locked, period: 4.4, delay: 0.4)
        }
        .background(Theme.sWindow.opacity(0.7))
        .animation(Motion.spring, value: words)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    @ObservedObject var store: NoteStore
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.sAccent.opacity(0.8))
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
            Text("Nothing open")
                .font(Font(Theme.serif(19)))
                .foregroundStyle(Theme.sTextPrimary)
            Text("Pick a note, or start something new.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.sTextTertiary)
            Button {
                withAnimation(Motion.spring) { _ = store.newNote() }
            } label: {
                Text("New note")
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(Theme.sAccent, in: Capsule())
                    .foregroundStyle(Color(Theme.windowBG))
            }
            .buttonStyle(.plain)
            .pressable()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(Motion.spring) { appeared = true } }
    }
}

// MARK: - Keyboard

/// Window-level shortcuts that aren't in the menu bar: ⌘K, escape, mode toggle,
/// and palette arrow navigation.
private struct KeyCatcher: NSViewRepresentable {
    @ObservedObject var app: AppState
    @ObservedObject var store: NoteStore
    var onNewSketch: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(app: app, store: store)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.app = app
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var app: AppState?
        private var monitor: Any?

        func install(app: AppState, store: NoteStore) {
            self.app = app
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let app = self?.app else { return event }
                let command = event.modifierFlags.contains(.command)
                let shift = event.modifierFlags.contains(.shift)
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

                if command && key == "k" {
                    Task { @MainActor in
                        app.paletteOpen ? app.closePalette() : app.openPalette()
                    }
                    return nil
                }
                if command && shift && key == "m" {
                    Task { @MainActor in app.toggleMode() }
                    return nil
                }
                if command && key == "\\" {
                    Task { @MainActor in app.toggleSidebar() }
                    return nil
                }
                if event.keyCode == 53, app.paletteOpen {      // escape
                    Task { @MainActor in app.closePalette() }
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Emoji picker

struct EmojiPicker: View {
    let onPick: (String) -> Void

    private let emojis = ["📝", "📓", "💡", "🚀", "🎯", "🧠", "📌", "🔥",
                          "✅", "🗓️", "📊", "🧪", "🎨", "🎵", "🍜", "✈️",
                          "🏋️", "💰", "🐛", "📚", "🌱", "⚙️", "🔗", "❤️"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Icon")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.sTextFaint)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 8),
                      spacing: 2) {
                ForEach(Array(emojis.enumerated()), id: \.element) { index, emoji in
                    Button { onPick(emoji) } label: {
                        Text(emoji)
                            .font(.system(size: 16))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .riseIn(index)
                }
            }
            Divider().overlay(Theme.sHairline)
            Button("Remove icon") { onPick("") }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.sTextSecondary)
        }
        .padding(12)
        .frame(width: 268)
        .background(Theme.sRaised)
    }
}
