import Foundation
import SwiftUI

/// Receives every local change so it can enter the sync outbox. Local storage
/// stays the source of truth; this is purely an additional durable record of
/// intent, and the app works identically with no delegate attached.
protocol NoteStoreSyncDelegate: AnyObject {
    func noteStore(_ store: NoteStore, didChange note: Note)
    func noteStore(_ store: NoteStore, didDelete noteID: UUID, drawingIDs: [UUID])
    func noteStore(_ store: NoteStore, didChangeDrawing drawing: Drawing, in noteID: UUID)
}

/// Owns the note library and its persistence. Notes live as individual `.md`
/// files so the library stays legible outside the app; drawings ride along in a
/// JSON sidecar per note.
final class NoteStore: ObservableObject {

    weak var syncDelegate: NoteStoreSyncDelegate?

    @Published var notes: [Note] = []
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { refreshDisplayOrder() } }
    }
    @Published var search: String = ""

    /// The sidebar's running order.
    ///
    /// Deliberately *not* recomputed while you type. Sorting live by `updated`
    /// makes the note you're editing jump to the top on every keystroke, which
    /// shuffles the whole list under the cursor. This settles instead when
    /// something structural happens — a note added, removed, pinned, or a
    /// different note selected.
    @Published private(set) var displayOrder: [UUID] = []

    let root: URL
    private var pendingSaves: Set<UUID> = []
    private var saveTimer: Timer?

    init(root: URL? = nil) {
        let base = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NatesNotes", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
        if notes.isEmpty { seedWelcomeNote() }
        refreshDisplayOrder()
        selectedID = sortedNotes.first?.id
    }

    // MARK: - Derived

    /// A true recency sort. Used where a fresh answer matters more than
    /// stability — the command palette, and for recomputing `displayOrder`.
    var sortedNotes: [Note] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }

    /// The stable order the sidebar renders. Notes not yet in `displayOrder`
    /// (just created) sort to the front.
    var orderedNotes: [Note] {
        var rank: [UUID: Int] = [:]
        for (index, id) in displayOrder.enumerated() { rank[id] = index }
        return notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return (rank[a.id] ?? -1) < (rank[b.id] ?? -1)
        }
    }

    var filteredNotes: [Note] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        // Searching is an explicit act, so re-ranking by relevance/recency is
        // expected there; only the resting list needs to hold still.
        guard !q.isEmpty else { return orderedNotes }
        return sortedNotes.filter {
            $0.title.lowercased().contains(q) || $0.text.lowercased().contains(q)
        }
    }

    private func refreshDisplayOrder() {
        displayOrder = sortedNotes.map(\.id)
    }

    var selected: Note? {
        guard let id = selectedID else { return nil }
        return notes.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? { notes.firstIndex { $0.id == id } }

    // MARK: - Mutation

    func updateText(_ text: String, for id: UUID) {
        guard let i = index(of: id), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        scheduleSave(id)
        syncDelegate?.noteStore(self, didChange: notes[i])
    }

    func setDrawing(_ drawing: Drawing, for noteID: UUID, propagate: Bool = true) {
        guard let i = index(of: noteID) else { return }
        guard notes[i].drawings[drawing.id] != drawing else { return }
        notes[i].drawings[drawing.id] = drawing
        notes[i].updated = Date()
        scheduleSave(noteID)
        if propagate { syncDelegate?.noteStore(self, didChangeDrawing: drawing, in: noteID) }
    }

    /// Adds a note that came from elsewhere (a remote pull, or a conflict copy).
    func insert(_ note: Note, propagate: Bool) {
        if let i = index(of: note.id) {
            notes[i] = note
        } else {
            notes.append(note)
            refreshDisplayOrder()
        }
        scheduleSave(note.id)
        if propagate { syncDelegate?.noteStore(self, didChange: note) }
    }

    func replace(_ note: Note, propagate: Bool) {
        guard let i = index(of: note.id) else { return insert(note, propagate: propagate) }
        notes[i] = note
        scheduleSave(note.id)
        if propagate { syncDelegate?.noteStore(self, didChange: note) }
    }

    func drawing(_ drawingID: UUID, in noteID: UUID) -> Drawing? {
        guard let i = index(of: noteID) else { return nil }
        return notes[i].drawings[drawingID]
    }

    func togglePin(_ id: UUID) {
        guard let i = index(of: id) else { return }
        notes[i].pinned.toggle()
        refreshDisplayOrder()
        scheduleSave(id)
        syncDelegate?.noteStore(self, didChange: notes[i])
    }

    func setEmoji(_ emoji: String, for id: UUID) {
        guard let i = index(of: id) else { return }
        notes[i].emoji = emoji
        scheduleSave(id)
        syncDelegate?.noteStore(self, didChange: notes[i])
    }

    @discardableResult
    func newNote(text: String = "") -> Note {
        let note = Note(text: text)
        notes.append(note)
        refreshDisplayOrder()
        selectedID = note.id
        scheduleSave(note.id)
        syncDelegate?.noteStore(self, didChange: note)
        return note
    }

    func delete(_ id: UUID, propagate: Bool = true) {
        guard let i = index(of: id) else { return }
        let wasSelected = selectedID == id
        let drawingIDs = Array(notes[i].drawings.keys)
        notes.remove(at: i)
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: drawingsURL(id))
        refreshDisplayOrder()
        if wasSelected { selectedID = sortedNotes.first?.id }
        if propagate { syncDelegate?.noteStore(self, didDelete: id, drawingIDs: drawingIDs) }
    }

    /// Every conflict copy, gone in one stroke. Deletion propagates, so the
    /// copies disappear from the other devices too.
    func deleteAllConflictCopies() {
        let ids = notes.filter(\.isConflictCopy).map(\.id)
        for id in ids { delete(id) }
    }

    func duplicate(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        var copy = note
        copy.id = UUID()
        copy.created = Date()
        copy.updated = Date()
        copy.pinned = false
        notes.append(copy)
        refreshDisplayOrder()
        selectedID = copy.id
        scheduleSave(copy.id)
        syncDelegate?.noteStore(self, didChange: copy)
    }

    // MARK: - Persistence

    private func fileURL(_ id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).md")
    }

    private func drawingsURL(_ id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).drawings.json")
    }

    private func scheduleSave(_ id: UUID) {
        pendingSaves.insert(id)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    /// Writes every dirty note. Called on a debounce and again at quit.
    func flush() {
        let ids = pendingSaves
        pendingSaves.removeAll()
        for id in ids {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            do {
                try note.serialized().write(to: fileURL(id), atomically: true, encoding: .utf8)
                if note.drawings.isEmpty {
                    try? FileManager.default.removeItem(at: drawingsURL(id))
                } else {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let payload = Array(note.drawings.values)
                    let data = try encoder.encode(payload)
                    try data.write(to: drawingsURL(id), options: .atomic)
                }
            } catch {
                NSLog("NatesNotes: save failed for \(id): \(error)")
            }
        }
    }

    private func load() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil) else { return }
        var loaded: [Note] = []
        for url in entries where url.pathExtension == "md" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallback = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            var note = Note.parse(raw, fallbackID: fallback)
            let sidecar = root.appendingPathComponent("\(note.id.uuidString).drawings.json")
            if let data = try? Data(contentsOf: sidecar),
               let list = try? JSONDecoder().decode([Drawing].self, from: data) {
                for d in list { note.drawings[d.id] = d }
            }
            loaded.append(note)
        }
        notes = loaded
    }

    private func seedWelcomeNote() {
        let note = Note(text: WelcomeContent.markdown)
        notes = [note]
        pendingSaves.insert(note.id)
        flush()
    }
}
