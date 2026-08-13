import SwiftUI
import UIKit

struct NoteEditorScreen: View {
    @EnvironmentObject private var notes: NoteStore
    let noteID: UUID

    @State private var viewing: Drawing?

    var body: some View {
        MarkdownEditor(noteID: noteID, onOpenDrawing: { viewing = $0 })
            .environmentObject(notes)
            .background(Color(Theme.windowBG).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(notes.notes.first { $0.id == noteID }?.title ?? "Note")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(Color(Theme.textSecondary))
                        .lineLimit(1)
                }
            }
            .sheet(item: $viewing) { drawing in
                DrawingViewer(drawing: drawing)
            }
    }
}

/// Bridges the UIKit editor into SwiftUI.
struct MarkdownEditor: UIViewRepresentable {
    @EnvironmentObject private var notes: NoteStore
    let noteID: UUID
    let onOpenDrawing: (Drawing) -> Void

    func makeUIView(context: Context) -> MarkdownEditorTextView {
        let view = MarkdownEditorTextView()
        view.mdDelegate = context.coordinator
        view.setMarkdown(notes.notes.first { $0.id == noteID }?.text ?? "")
        context.coordinator.observeMode(view)
        return view
    }

    func updateUIView(_ view: MarkdownEditorTextView, context: Context) {
        context.coordinator.notes = notes
        context.coordinator.noteID = noteID
        // Adopt outside changes (a sync pull) even while the keyboard is up —
        // skipping them here used to let the next keystroke push the editor's
        // stale buffer back over the merged note, silently discarding the other
        // device's edit. The sync layer already waits out active typing, and
        // `setMarkdown` keeps the caret with its content; only in-progress IME
        // composition is never interrupted.
        if let text = notes.notes.first(where: { $0.id == noteID })?.text,
           text != view.markdown, view.markedTextRange == nil {
            view.setMarkdown(text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(notes: notes, noteID: noteID, onOpenDrawing: onOpenDrawing)
    }

    final class Coordinator: MarkdownEditorDelegate {
        var notes: NoteStore
        var noteID: UUID
        let onOpenDrawing: (Drawing) -> Void
        private var observer: NSObjectProtocol?

        init(notes: NoteStore, noteID: UUID, onOpenDrawing: @escaping (Drawing) -> Void) {
            self.notes = notes
            self.noteID = noteID
            self.onOpenDrawing = onOpenDrawing
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func observeMode(_ view: MarkdownEditorTextView) {
            observer = NotificationCenter.default.addObserver(
                forName: .nnModeChanged, object: nil, queue: .main
            ) { [weak view] _ in
                view?.tintColor = Theme.accent
                view?.invalidateDrawings()
            }
        }

        func markdownEditorDidEdit(_ view: MarkdownEditorTextView) {
            notes.updateText(view.markdown, for: noteID)
        }

        func markdownEditor(_ view: MarkdownEditorTextView, drawingFor id: UUID) -> Drawing? {
            notes.drawing(id, in: noteID)
        }

        func markdownEditor(_ view: MarkdownEditorTextView, didTapDrawing id: UUID) {
            guard let drawing = notes.drawing(id, in: noteID) else { return }
            onOpenDrawing(drawing)
        }
    }
}

/// Read-only for now: sketches sync down and can be looked at full screen, but
/// editing one still needs the touch canvas that hasn't been built yet.
struct DrawingViewer: View {
    let drawing: Drawing
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.canvasBG).ignoresSafeArea()
                GeometryReader { geo in
                    if let image = ElementPainter.image(
                        for: drawing,
                        maxSize: CGSize(width: geo.size.width * 2, height: geo.size.height * 2),
                        isDark: true
                    ) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoom)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .gesture(MagnificationGesture()
                                .onChanged { zoom = max(0.5, min(4, $0)) }
                                .onEnded { _ in withAnimation(.spring) { zoom = max(1, zoom) } })
                    } else {
                        Text("Empty drawing")
                            .foregroundStyle(Color(Theme.textTertiary))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .navigationTitle("Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
