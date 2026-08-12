import Foundation
import SwiftUI
import SyncKit

/// Bridges `NoteStore` to `SyncEngine`: turns local edits into durable outbox
/// intent, and folds remote documents back into local storage through the
/// three-way merge.
@MainActor
final class SyncController: ObservableObject {

    enum Status: Equatable {
        case unpaired
        case idle
        case syncing
        case offline(String)
        case needsPairing(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .unpaired
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var conflicts: [ConflictRecord] = []
    @Published var settings: SyncSettings

    /// Everything sync needs on disk. Absent only if the state directory can't
    /// be created, in which case the app runs normally without syncing rather
    /// than refusing to launch.
    private struct Backend {
        let engine: SyncEngine
        let store: SyncStateStore
        let credentials: CredentialStore
    }

    private let backend: Backend?
    private weak var notes: NoteStore?
    private var timer: Timer?
    private var autoSyncWork: DispatchWorkItem?
    /// Suppresses the echo when we write remote content into the local store.
    private var isApplyingRemote = false

    var isAvailable: Bool { backend != nil }

    private var currentState: SyncState {
        backend?.store.state ?? SyncState()
    }

    var deviceName: String {
        currentState.deviceName ?? Device.name
    }

    var installationId: String { currentState.installationId }

    /// The configured server, for display.
    var serverDescription: String { settings.baseURL.absoluteString }

    /// Stores where to sync. Changing it drops the pairing, since a device
    /// token only means anything to the server that issued it.
    func setServer(_ address: String) {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.host != nil else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: SyncSettings.baseURLDefaultsKey)
        Task { await unpair() }
    }

    init(notes: NoteStore, settings: SyncSettings = .standard(), root: URL? = nil) {
        let directory = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NatesNotes/sync", isDirectory: true)

        self.settings = settings
        self.notes = notes

        do {
            let store = try SyncStateStore(directory: directory)
            let credentials = KeychainCredentialStore()
            let blobs = try BlobStore(
                directory: directory.appendingPathComponent("blobs", isDirectory: true))
            let transport = HTTPSyncTransport(settings: settings, credentials: credentials)
            self.backend = Backend(
                engine: SyncEngine(transport: transport, store: store, blobs: blobs,
                                   credentials: credentials, settings: settings),
                store: store,
                credentials: credentials)
        } catch {
            self.backend = nil
            self.status = .failed("Sync unavailable: \(error.localizedDescription)")
        }

        notes.syncDelegate = self
        refreshPublished()
        if let backend, backend.store.state.isPaired,
           (try? backend.credentials.token()) != nil {
            status = .idle
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard backend != nil, timer == nil else { return }
        // Edits trigger their own debounced sync, so this is only the safety
        // net that catches remote changes and anything the debounce missed.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "timer") }
        }
        Task { await syncNow(reason: "launch") }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        autoSyncWork?.cancel()
    }

    /// Syncs shortly after typing stops.
    ///
    /// Every keystroke re-queues the note, so syncing per edit would be both
    /// chatty and pointless — the debounce lets a burst of typing settle into
    /// one push, which is what makes sync feel automatic rather than something
    /// you watch happen.
    private func scheduleAutoSync(after delay: TimeInterval = 2.5) {
        guard backend != nil else { return }
        autoSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow(reason: "auto") }
        }
        autoSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Pairing

    func pair(code: String) async -> Result<String, Error> {
        guard let backend else { return .failure(SyncError.notPaired) }
        status = .syncing
        do {
            let space = try await backend.engine.pair(code: code, deviceName: hostName())
            // Everything written before pairing has no outbox intent yet, so
            // seed it — otherwise an existing library would never upload.
            await enqueueEntireLibrary()
            refreshPublished()
            status = .idle
            await syncNow(reason: "paired")
            return .success(space.displayName)
        } catch {
            status = .needsPairing(Self.describe(error))
            return .failure(error)
        }
    }

    func unpair() async {
        guard let backend else { return }
        await backend.engine.unpair()
        refreshPublished()
        status = .unpaired
    }

    // MARK: - Sync

    func syncNow(reason: String) async {
        guard let backend else { return }
        guard backend.store.state.isPaired,
              (try? backend.credentials.token()) != nil else {
            status = .unpaired
            return
        }
        guard status != .syncing else {
            // Don't drop the request — retry once the current pass finishes,
            // or these edits would wait for the next safety-net tick.
            scheduleAutoSync(after: 1)
            return
        }
        status = .syncing
        do {
            let outcome = try await backend.engine.sync()
            await applyRemote(outcome)
            refreshPublished()
            status = .idle
            // Edits that landed mid-sync are still queued; go again.
            if pendingCount > 0 { scheduleAutoSync(after: 1) }
        } catch let error as SyncError {
            switch error {
            case .unauthorized:
                status = .needsPairing("This device's access was revoked. Pair again to resume.")
            case .transient, .cancelled:
                status = .offline("Can't reach the sync server")
            default:
                status = .failed(Self.describe(error))
            }
            refreshPublished()
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    /// Folds verified remote content into local storage.
    ///
    /// Every merge base this establishes is committed before the pass returns.
    /// The next pull reads those bases to tell "they changed it" apart from "I
    /// changed it"; one that lands late leaves the following pull comparing
    /// against pre-push content, so this device reads its own last write as a
    /// stranger's edit — a conflict with nobody but itself.
    private func applyRemote(_ outcome: SyncOutcome) async {
        guard let notes else { return }
        var reconciled: [(nodeId: String, content: Data)] = []
        isApplyingRemote = true

        for document in outcome.updated {
            switch document.folder {
            case SyncEngine.notesFolder:
                applyRemoteNote(document, into: notes, reconciled: &reconciled)
            case SyncEngine.drawingsFolder:
                applyRemoteDrawing(document, into: notes, reconciled: &reconciled)
            default:
                break
            }
        }

        for tombstone in outcome.removed where tombstone.folder == SyncEngine.notesFolder {
            let id = UUID(uuidString: (tombstone.name as NSString).deletingPathExtension)
            if let id, notes.notes.contains(where: { $0.id == id }) {
                notes.delete(id, propagate: false)
            }
        }

        isApplyingRemote = false

        if let backend {
            for entry in reconciled {
                try? await backend.engine.recordMergeBase(nodeId: entry.nodeId,
                                                          content: entry.content)
            }
        }
    }

    private func applyRemoteNote(_ document: RemoteDocument, into notes: NoteStore,
                                 reconciled: inout [(nodeId: String, content: Data)]) {
        guard let remote = NoteDocument(data: document.content) else { return }
        let base = document.base.flatMap { NoteDocument(data: $0) }

        guard let index = notes.index(of: remote.id) else {
            // New to this device.
            var note = Note(id: remote.id)
            remote.apply(to: &note)
            notes.insert(note, propagate: false)
            reconciled.append((document.nodeId, document.content))
            return
        }

        let local = NoteDocument(note: notes.notes[index])
        switch NoteMerge.merge(base: base, local: local, remote: remote) {
        case .keepLocal:
            reconciled.append((document.nodeId, document.content))

        case .useRemote(let merged):
            var note = notes.notes[index]
            merged.apply(to: &note)
            notes.replace(note, propagate: false)
            reconciled.append((document.nodeId, document.content))

        case .merged(let merged):
            var note = notes.notes[index]
            merged.apply(to: &note)
            notes.replace(note, propagate: false)
            // A merged result is new content, so it goes back as fresh intent.
            enqueueNote(note)
            reconciled.append((document.nodeId, document.content))

        case .conflict(_, let remoteDoc):
            // Local stays live; the server's version is preserved as its own
            // note so no edit is lost on any device. A record owns exactly one
            // outstanding copy — a record that conflicts repeatedly refreshes
            // that copy rather than adding another note each time.
            let copy = NoteMerge.conflictCopy(of: remoteDoc, source: remote.id)
            if let existing = notes.index(of: copy.id) {
                // Never overwrite a copy the user has started working in.
                if NoteMerge.isUntouchedConflictCopy(notes.notes[existing]),
                   notes.notes[existing].text != copy.text {
                    var refreshed = notes.notes[existing]
                    refreshed.text = copy.text
                    refreshed.updated = copy.updated
                    notes.replace(refreshed, propagate: true)
                }
            } else {
                notes.insert(copy, propagate: true)
            }
            reconciled.append((document.nodeId, document.content))
            enqueueNote(notes.notes[index])
        }
    }

    private func applyRemoteDrawing(_ document: RemoteDocument, into notes: NoteStore,
                                    reconciled: inout [(nodeId: String, content: Data)]) {
        guard let remote = DrawingDocument(data: document.content) else { return }
        guard let noteIndex = notes.index(of: remote.noteId) else { return }
        let existing = notes.notes[noteIndex].drawings[remote.id]
        if existing?.elements != remote.elements {
            notes.setDrawing(remote.drawing, for: remote.noteId, propagate: false)
        }
        reconciled.append((document.nodeId, document.content))
    }

    // MARK: - Conflicts

    func openConflicts() -> [ConflictRecord] {
        currentState.conflicts.filter { !$0.resolved }
    }

    /// Keeps this device's version and pushes it against the server's current
    /// version, which is what actually clears the conflict.
    func resolveKeepingLocal(_ conflict: ConflictRecord) {
        guard let backend else { return }
        Task {
            try? await backend.engine.resolveConflict(conflict.id,
                                                      mergedContent: conflict.localContent)
            await syncNow(reason: "conflict-resolved")
        }
    }

    /// Accepts the server's version locally, dropping this device's edit only
    /// after the user explicitly asks for it.
    func resolveTakingRemote(_ conflict: ConflictRecord) {
        guard let backend else { return }
        Task {
            try? await backend.engine.resolveConflict(conflict.id, mergedContent: nil)
            await syncNow(reason: "conflict-resolved")
        }
    }

    func dismissResolved() {
        guard let backend else { return }
        Task { try? await backend.engine.clearResolvedConflicts(); refreshPublished() }
    }

    // MARK: - Outbox intent

    /// Records intent for every local note and drawing. Coalescing means this is
    /// safe to call repeatedly — it tops up anything missing without duplicating
    /// what's already queued.
    private func enqueueEntireLibrary() async {
        guard let backend, let notes else { return }
        for note in notes.notes {
            let document = NoteDocument(note: note)
            try? await backend.engine.enqueueUpsert(
                recordKey: NoteDocument.recordKey(for: note.id),
                folder: SyncEngine.notesFolder,
                fileName: NoteDocument.fileName(for: note.id),
                mediaType: NoteDocument.mediaType,
                appProperties: NoteDocument.appProperties(),
                content: document.canonicalData())

            for (drawingID, drawing) in note.drawings {
                let drawingDocument = DrawingDocument(drawing: drawing, noteId: note.id)
                try? await backend.engine.enqueueUpsert(
                    recordKey: DrawingDocument.recordKey(for: drawingID),
                    folder: SyncEngine.drawingsFolder,
                    fileName: DrawingDocument.fileName(for: drawingID),
                    mediaType: DrawingDocument.mediaType,
                    appProperties: DrawingDocument.appProperties(noteId: note.id),
                    content: drawingDocument.canonicalData())
            }
        }
        refreshPublished()
    }

    private func enqueueNote(_ note: Note) {
        let document = NoteDocument(note: note)
        try? engineEnqueueUpsert(recordKey: NoteDocument.recordKey(for: note.id),
                                 folder: SyncEngine.notesFolder,
                                 fileName: NoteDocument.fileName(for: note.id),
                                 mediaType: NoteDocument.mediaType,
                                 appProperties: NoteDocument.appProperties(),
                                 content: document.canonicalData())
    }

    /// The engine is an actor; these calls are fire-and-forget because the
    /// intent is durable the moment the actor commits it.
    private func engineEnqueueUpsert(recordKey: String, folder: String, fileName: String,
                                     mediaType: String, appProperties: [String: JSONValue],
                                     content: Data) throws {
        guard let backend else { return }
        Task {
            try? await backend.engine.enqueueUpsert(recordKey: recordKey, folder: folder,
                                                    fileName: fileName, mediaType: mediaType,
                                                    appProperties: appProperties,
                                                    content: content)
            await MainActor.run {
                self.refreshPublished()
                self.scheduleAutoSync()
            }
        }
    }

    private func refreshPublished() {
        let state = currentState
        // Only work a sync pass can actually move. A blocked item waits on a
        // resolution, not on another pass — counting it here would make
        // `syncNow` reschedule itself every second for as long as it sits there.
        pendingCount = state.outbox.count { $0.status != .blocked }
        conflicts = state.conflicts.filter { !$0.resolved }
        lastSyncedAt = state.lastSyncedAt.flatMap(SyncTime.date)
    }

    private func hostName() -> String {
        Device.name
    }

    static func describe(_ error: Error) -> String {
        guard let syncError = error as? SyncError else { return error.localizedDescription }
        switch syncError {
        case .unauthorized: return "Access revoked — pair this device again."
        case .forbidden: return "That pairing code is invalid, expired, or already used."
        case .transient: return "Can't reach the sync server."
        case .notPaired: return "Not paired yet."
        case .corruptDownload: return "A downloaded file failed verification."
        case .gone: return "Sync history expired; taking a fresh snapshot."
        case .permanent(let status, _): return "Server rejected the request (\(status))."
        case .malformedResponse(let detail): return "Unexpected server response: \(detail)"
        case .offsetConflict, .checksumMismatch: return "Upload interrupted; will resume."
        case .cancelled: return "Cancelled."
        }
    }
}

// MARK: - NoteStore bridge

extension SyncController: NoteStoreSyncDelegate {

    nonisolated func noteStore(_ store: NoteStore, didChange note: Note) {
        Task { @MainActor in
            guard !isApplyingRemote else { return }
            enqueueNote(note)
        }
    }

    nonisolated func noteStore(_ store: NoteStore, didDelete noteID: UUID,
                               drawingIDs: [UUID]) {
        Task { @MainActor in
            guard !isApplyingRemote, let backend else { return }
            try? await backend.engine.enqueueDelete(
                recordKey: NoteDocument.recordKey(for: noteID),
                folder: SyncEngine.notesFolder,
                fileName: NoteDocument.fileName(for: noteID))
            for drawingID in drawingIDs {
                try? await backend.engine.enqueueDelete(
                    recordKey: DrawingDocument.recordKey(for: drawingID),
                    folder: SyncEngine.drawingsFolder,
                    fileName: DrawingDocument.fileName(for: drawingID))
            }
            refreshPublished()
            scheduleAutoSync()
        }
    }

    nonisolated func noteStore(_ store: NoteStore, didChangeDrawing drawing: Drawing,
                               in noteID: UUID) {
        Task { @MainActor in
            guard !isApplyingRemote else { return }
            let document = DrawingDocument(drawing: drawing, noteId: noteID)
            try? engineEnqueueUpsert(
                recordKey: DrawingDocument.recordKey(for: drawing.id),
                folder: SyncEngine.drawingsFolder,
                fileName: DrawingDocument.fileName(for: drawing.id),
                mediaType: DrawingDocument.mediaType,
                appProperties: DrawingDocument.appProperties(noteId: noteID),
                content: document.canonicalData())
        }
    }
}
