import SwiftUI
import AppKit

extension Notification.Name {
    /// Broadcast when the accent changes, so AppKit-drawn surfaces re-tint.
    static let themeDidChange = Notification.Name("nn.themeDidChange")
}

/// UI-level state that isn't part of the note model: mode, chrome visibility,
/// the command palette, and which drawing is currently open in the modal.
@MainActor
final class AppState: ObservableObject {

    @Published var mode: AppMode = .chill {
        didSet {
            guard mode != oldValue else { return }
            Theme.mode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "nn.mode")
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    @Published var sidebarVisible = true
    @Published var paletteOpen = false
    @Published var paletteQuery = ""

    /// Non-nil while the drawing modal is open.
    @Published var openDrawing: OpenDrawing?

    /// Where the morph starts from, in window coordinates.
    struct OpenDrawing: Equatable {
        var noteID: UUID
        var drawingID: UUID
        var sourceRect: CGRect
        /// Still frame of the sketch, shown while the modal morphs open.
        var preview: NSImage?

        static func == (a: OpenDrawing, b: OpenDrawing) -> Bool {
            a.drawingID == b.drawingID && a.noteID == b.noteID && a.sourceRect == b.sourceRect
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "nn.mode"),
           let saved = AppMode(rawValue: raw) {
            mode = saved
        }
        Theme.mode = mode
    }

    func toggleMode() {
        withAnimation(Motion.mode) { mode = mode.toggled }
    }

    func toggleSidebar() {
        withAnimation(Motion.spring) { sidebarVisible.toggle() }
    }

    func openPalette() {
        paletteQuery = ""
        withAnimation(Motion.spring) { paletteOpen = true }
    }

    func closePalette() {
        withAnimation(Motion.fade) { paletteOpen = false }
    }
}
