import SwiftUI
import AppKit

/// SwiftUI wrapper around `MarkdownTextView`, in a scroll view that keeps the
/// text in a centred reading column.
struct MarkdownEditor: NSViewRepresentable {

    let noteID: UUID
    @Binding var text: String
    let drawingProvider: (UUID) -> Drawing?
    let onOpenDrawing: (UUID, CGRect) -> Void
    let onCreateDrawing: (@escaping (UUID) -> Void) -> Void
    /// Bumped by the parent after a drawing is edited, to re-render thumbnails.
    var redrawTick: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make()
        textView.mdDelegate = context.coordinator
        textView.string = text
        textView.restyle()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = textView

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        context.coordinator.textView = textView
        context.coordinator.currentNoteID = noteID

        DispatchQueue.main.async {
            scroll.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self

        if context.coordinator.currentNoteID != noteID {
            context.coordinator.currentNoteID = noteID
            context.coordinator.applyExternalText(text, scrollToTop: true)
            textView.invalidateImageCache()
        } else if textView.string != text && !context.coordinator.isTyping
                    && !textView.hasMarkedText() {
            context.coordinator.applyExternalText(text, scrollToTop: false)
        }

        if context.coordinator.lastRedrawTick != redrawTick {
            context.coordinator.lastRedrawTick = redrawTick
            textView.invalidateImageCache()
        }
    }

    final class Coordinator: NSObject, MarkdownTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        var currentNoteID: UUID?
        var isTyping = false
        var lastRedrawTick = 0

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        /// Puts outside content into the view. Opening a different note starts
        /// at the top; the same note being refreshed underneath (a sync pull)
        /// keeps the caret and viewport where the user left them.
        func applyExternalText(_ text: String, scrollToTop: Bool) {
            guard let textView else { return }
            let caret = TextSync.remappedCaret(textView.selectedRange(),
                                               from: textView.string, to: text)
            textView.string = text
            textView.setSelectedRange(scrollToTop ? NSRange(location: 0, length: 0) : caret)
            textView.restyle()
            if scrollToTop {
                textView.enclosingScrollView?.documentView?.scroll(.zero)
            }
        }

        func markdownTextViewDidEdit(_ view: MarkdownTextView) {
            isTyping = true
            parent.text = view.string
            DispatchQueue.main.async { self.isTyping = false }
        }

        func markdownTextView(_ view: MarkdownTextView, didClickDrawing id: UUID,
                              at rect: CGRect) {
            parent.onOpenDrawing(id, rect)
        }

        func markdownTextViewRequestsNewDrawing(_ view: MarkdownTextView) {
            parent.onCreateDrawing { [weak view] id in
                guard let view else { return }
                let needsLeadingBreak = !view.string.isEmpty
                    && !view.string.hasSuffix("\n")
                let snippet = (needsLeadingBreak ? "\n" : "") + "![](drawing://\(id.uuidString))\n"
                view.insertBlock(snippet)
                view.restyle()
            }
        }

        func markdownTextView(_ view: MarkdownTextView, drawingFor id: UUID) -> Drawing? {
            parent.drawingProvider(id)
        }
    }
}
