import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var notes: NoteStore
    @EnvironmentObject private var sync: SyncController
    @Binding var mode: AppMode

    @State private var search = ""
    @State private var showingSync = false
    @State private var openNote: UUID?
    @State private var confirmDeleteConflicts = false

    private var matching: [Note] {
        let all = notes.sortedNotes
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.text.localizedCaseInsensitiveContains(search)
        }
    }

    private var visible: [Note] { matching.filter { !$0.isConflictCopy } }
    private var conflictCopies: [Note] { matching.filter(\.isConflictCopy) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.windowBG).ignoresSafeArea()

                if visible.isEmpty && conflictCopies.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No notes yet" : "Nothing matches",
                        systemImage: search.isEmpty ? "doc.text" : "magnifyingglass",
                        description: Text(search.isEmpty
                                          ? "Tap the pencil to start writing."
                                          : "Try a different search.")
                    )
                } else {
                    List {
                        ForEach(visible) { note in
                            noteLink(note)
                        }
                        if !conflictCopies.isEmpty {
                            Section {
                                ForEach(conflictCopies) { note in
                                    noteLink(note)
                                }
                            } header: {
                                HStack {
                                    Text("Conflicts")
                                        .foregroundStyle(.orange.opacity(0.85))
                                    Spacer()
                                    Button("Delete All", role: .destructive) {
                                        confirmDeleteConflicts = true
                                    }
                                    .font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .confirmationDialog(
                        "Delete all \(conflictCopies.count) conflict copies?",
                        isPresented: $confirmDeleteConflicts,
                        titleVisibility: .visible) {
                        Button("Delete All", role: .destructive) {
                            notes.deleteAllConflictCopies()
                        }
                    } message: {
                        Text("Merge anything worth keeping into the original notes first. This removes the copies from every synced device.")
                    }
                }
            }
            .navigationTitle("Nate's Notes")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, prompt: "Search notes")
            .navigationDestination(for: UUID.self) { id in
                NoteEditorScreen(noteID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSync = true
                    } label: {
                        Image(systemName: sync.statusSymbol)
                            .foregroundStyle(Color(sync.statusTint))
                    }
                    .accessibilityLabel("Sync")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { mode = mode.toggled } label: {
                        Text(mode.shortLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color(Theme.accent).opacity(0.18)))
                            .foregroundStyle(Color(Theme.accent))
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        openNote = notes.newNote().id
                    } label: {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(item: $openNote) { id in
                NoteEditorScreen(noteID: id)
            }
            .onAppear {
                // Opens straight into a note so the editor can be captured
                // without a tap, the way --render-samples works on the Mac.
                if ProcessInfo.processInfo.arguments.contains("-nnOpenFirstNote") {
                    openNote = notes.sortedNotes.first?.id
                }
            }
        }
        .sheet(isPresented: $showingSync) { SyncSheet() }
    }

    private func noteLink(_ note: Note) -> some View {
        NavigationLink(value: note.id) {
            NoteRow(note: note)
        }
        .listRowBackground(Color(Theme.panelBG))
        .swipeActions(edge: .leading) {
            Button {
                notes.togglePin(note.id)
            } label: {
                Label(note.pinned ? "Unpin" : "Pin",
                      systemImage: note.pinned ? "pin.slash" : "pin")
            }
            .tint(Color(Theme.accent))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                notes.delete(note.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(Theme.accent))
                }
                if !note.emoji.isEmpty { Text(note.emoji) }
                Text(note.title)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(Color(Theme.textPrimary))
                    .lineLimit(1)
            }
            Text(note.preview)
                .font(.subheadline)
                .foregroundStyle(Color(Theme.textTertiary))
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
