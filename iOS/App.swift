import SwiftUI
import SyncKit

@main
struct NatesNotesApp: App {
    @StateObject private var notes: NoteStore
    @StateObject private var sync: SyncController
    @State private var mode: AppMode = .chill

    init() {
        let store = NoteStore()
        _notes = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncController(notes: store))
        Theme.mode = .chill
    }

    var body: some Scene {
        WindowGroup {
            NoteListView(mode: $mode)
                .environmentObject(notes)
                .environmentObject(sync)
                .preferredColorScheme(.dark)
                .tint(Color(Theme.accent))
                .onAppear { sync.start() }
                .onChange(of: mode) { _, new in
                    Theme.mode = new
                    NotificationCenter.default.post(name: .nnModeChanged, object: nil)
                }
        }
    }
}

extension Notification.Name {
    /// The AppKit/UIKit layers read `Theme.mode` directly rather than taking a
    /// SwiftUI dependency, so they need a nudge when it changes.
    static let nnModeChanged = Notification.Name("nn.modeChanged")
}
