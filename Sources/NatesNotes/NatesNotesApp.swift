import SwiftUI
import AppKit

@main
struct NatesNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore()
    @StateObject private var sync: SyncController

    init() {
        let store = NoteStore()
        _store = StateObject(wrappedValue: store)
        // Sync degrades to "unavailable" rather than blocking launch.
        _sync = StateObject(wrappedValue: SyncController(notes: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, sync: sync)
                .frame(minWidth: 940, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear { sync.start() }
                .onDisappear { store.flush(); sync.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { store.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Insert Drawing") {
                    sendToResponder(#selector(MarkdownTextView.insertDrawingMD(_:)))
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandMenu("Format") {
                Button("Bold") { sendToResponder(#selector(MarkdownTextView.toggleBoldMD(_:))) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { sendToResponder(#selector(MarkdownTextView.toggleItalicMD(_:))) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Code") { sendToResponder(#selector(MarkdownTextView.toggleCodeMD(_:))) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Strikethrough") { sendToResponder(#selector(MarkdownTextView.toggleStrikeMD(_:))) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Highlight") { sendToResponder(#selector(MarkdownTextView.toggleHighlightMD(_:))) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button("Heading 1") { sendToResponder(#selector(MarkdownTextView.makeHeading1(_:))) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Heading 2") { sendToResponder(#selector(MarkdownTextView.makeHeading2(_:))) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Heading 3") { sendToResponder(#selector(MarkdownTextView.makeHeading3(_:))) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("Body Text") { sendToResponder(#selector(MarkdownTextView.makeBody(_:))) }
                    .keyboardShortcut("0", modifiers: [.command, .option])

                Divider()

                Button("Bulleted List") { sendToResponder(#selector(MarkdownTextView.makeBulletList(_:))) }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Button("To-do") { sendToResponder(#selector(MarkdownTextView.makeTodo(_:))) }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                Button("Quote") { sendToResponder(#selector(MarkdownTextView.makeQuote(_:))) }
                    .keyboardShortcut("'", modifiers: [.command, .shift])
            }

            CommandGroup(after: .saveItem) {
                Button("Sync Now") {
                    Task { await sync.syncNow(reason: "menu") }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                Button("Nate's Notes Help") {
                    store.newNote(text: WelcomeContent.markdown)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set while a headless task owns the process, so closing the UI window
    /// doesn't terminate us out from under it.
    private var headless = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Live end-to-end check against the real server; exits when done.
        if let index = CommandLine.arguments.firstIndex(of: "--sync-smoke") {
            let code = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : ""
            let keep = CommandLine.arguments.contains("--keep")
            headless = true
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task { await LiveSmokeTest.run(code: code, keep: keep) }
            return
        }
        if SelfTest.runIfRequested() { exit(0) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Full-height sidebar look: let content run under the title bar.
        for window in NSApp.windows {
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = Theme.windowBG
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !headless
    }
}
