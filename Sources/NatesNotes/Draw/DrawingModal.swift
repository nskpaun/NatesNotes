import SwiftUI
import AppKit

/// The drawing surface, presented as a modal that grows out of the sketch card
/// you clicked.
///
/// The panel morphs from the card's exact rectangle to full size while the
/// diagram draws itself inside — expansion and ink land together, so it reads
/// as one gesture instead of a dialog appearing over a page.
struct DrawingModal: View {
    @ObservedObject var app: AppState
    @ObservedObject var controller: CanvasController
    let open: AppState.OpenDrawing
    var onClose: () -> Void

    @State private var expanded = false
    @State private var chromeIn = false
    @State private var scrim = false

    private let margin: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let full = CGRect(x: margin, y: margin,
                              width: max(320, geometry.size.width - margin * 2),
                              height: max(240, geometry.size.height - margin * 2))
            let source = sourceRect(in: geometry.size, fallback: full)
            let rect = expanded ? full : source

            ZStack {
                // Scrim: the page behind recedes rather than vanishing.
                Color.black
                    .opacity(scrim ? 0.55 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                panel
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(expanded ? 1 : 0.85)
            }
        }
        .onAppear { present() }
        .onExitCommand { close() }
    }

    // MARK: - Panel

    private var panel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: expanded ? 16 : 11, style: .continuous)
                .fill(Theme.sPanel)

            DrawingEditor(controller: controller, chromeIn: chromeIn, onDone: close)
                .clipShape(RoundedRectangle(cornerRadius: expanded ? 16 : 11, style: .continuous))
                // The contents scale up out of the card rather than snapping in.
                .opacity(expanded ? 1 : 0)
        }
        .overlay(
            RoundedRectangle(cornerRadius: expanded ? 16 : 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        )
        .overlay(
            // The accent traces the panel edge as it opens.
            RoundedRectangle(cornerRadius: expanded ? 16 : 11, style: .continuous)
                .strokeBorder(Theme.sAccent.opacity(expanded ? 0 : 0.9), lineWidth: 1.6)
                .blur(radius: expanded ? 6 : 0)
        )
        .shadow(color: .black.opacity(expanded ? 0.6 : 0), radius: 50, y: 22)
    }

    // MARK: - Choreography

    private func present() {
        controller.view.finishInkReveal()

        withAnimation(Motion.fade) { scrim = true }
        withAnimation(Motion.hero) { expanded = true }
        // Chrome arrives once the panel has most of its size.
        withAnimation(Motion.spring.delay(0.22)) { chromeIn = true }

        // Ink starts just after the growth begins, so the two overlap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            controller.view.playInkReveal(duration: 1.0)
            controller.focus()
        }
    }

    private func close() {
        controller.view.endTextEditing(commit: true)
        controller.view.finishInkReveal()
        withAnimation(Motion.fade) { chromeIn = false; scrim = false }
        withAnimation(Motion.hero) { expanded = false }
        // Let the collapse finish before tearing the overlay down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { onClose() }
    }

    /// The card's rectangle, already in the window's top-left coordinate space.
    private func sourceRect(in size: CGSize, fallback: CGRect) -> CGRect {
        let rect = open.sourceRect
        guard rect.width > 8, rect.height > 8 else {
            // No card to grow from (⇧⌘D from the keyboard): rise from the centre.
            return CGRect(x: size.width / 2 - 160, y: size.height / 2 - 100,
                          width: 320, height: 200)
        }
        return rect
    }
}
