import Foundation
import SyncKit

/// Canonical JSON representation of a note, per docs/SYNC.md.
///
/// Unknown fields survive the round trip so a newer client's additions aren't
/// stripped when this version rewrites the record.
struct NoteDocument: Equatable {
    static let schemaVersion = 1
    static let mediaType = "application/vnd.natesnotes.note+json"

    var id: UUID
    var body: String
    var pinned: Bool
    var emoji: String
    var createdAt: Date
    var modifiedAt: Date
    var drawingIds: [UUID]
    var extra: [String: JSONValue] = [:]

    /// `title` is derived, carried only so other clients can label the note
    /// without parsing markdown. Never merged — always recomputed from `body`.
    var title: String { Note(text: body).title }

    init(note: Note) {
        self.id = note.id
        self.body = note.text
        self.pinned = note.pinned
        self.emoji = note.emoji
        self.createdAt = note.created
        self.modifiedAt = note.updated
        self.drawingIds = note.drawings.keys.sorted { $0.uuidString < $1.uuidString }
    }

    init?(data: Data) {
        guard let raw = try? CanonicalJSON.decode(data),
              let object = raw.objectValue,
              let idString = object["id"]?.stringValue,
              let id = UUID(uuidString: idString) else { return nil }
        self.id = id
        self.body = object["body"]?.stringValue ?? ""
        self.pinned = object["pinned"]?.boolValue ?? false
        self.emoji = object["emoji"]?.stringValue ?? ""
        self.createdAt = (object["createdAt"]?.stringValue).flatMap(SyncTime.date) ?? Date()
        self.modifiedAt = (object["modifiedAt"]?.stringValue).flatMap(SyncTime.date) ?? Date()
        self.drawingIds = (object["drawingIds"]?.arrayValue ?? [])
            .compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
        let known: Set<String> = ["id", "body", "pinned", "emoji", "createdAt",
                                  "modifiedAt", "drawingIds", "schemaVersion", "title"]
        self.extra = object.filter { !known.contains($0.key) }
    }

    func canonicalData() -> Data {
        var object = extra
        object["schemaVersion"] = .int(NoteDocument.schemaVersion)
        object["id"] = .string(id.uuidString.lowercased())
        object["body"] = .string(body)
        object["pinned"] = .bool(pinned)
        object["emoji"] = .string(emoji)
        object["createdAt"] = .string(SyncTime.string(createdAt))
        object["modifiedAt"] = .string(SyncTime.string(modifiedAt))
        object["title"] = .string(title)
        object["drawingIds"] = .array(drawingIds.map { .string($0.uuidString.lowercased()) })
        return CanonicalJSON.encode(.object(object))
    }

    var fileName: String { "\(id.uuidString.lowercased()).json" }

    static func fileName(for id: UUID) -> String { "\(id.uuidString.lowercased()).json" }
    static func recordKey(for id: UUID) -> String { "note:\(id.uuidString.lowercased())" }

    static func appProperties() -> [String: JSONValue] {
        ["entityType": .string("note"), "schemaVersion": .int(schemaVersion)]
    }

    /// Applies this document onto a note, keeping local-only state intact.
    func apply(to note: inout Note) {
        note.text = body
        note.pinned = pinned
        note.emoji = emoji
        note.created = createdAt
        note.updated = modifiedAt
    }
}

/// Canonical JSON for one drawing. Viewport state is excluded on purpose —
/// panning is not a document mutation.
struct DrawingDocument: Equatable {
    static let schemaVersion = 1
    static let mediaType = "application/vnd.natesnotes.drawing+json"

    var id: UUID
    var noteId: UUID
    var elements: [DrawElement]
    var modifiedAt: Date
    var extra: [String: JSONValue] = [:]

    init(drawing: Drawing, noteId: UUID, modifiedAt: Date = Date()) {
        self.id = drawing.id
        self.noteId = noteId
        self.elements = drawing.elements
        self.modifiedAt = modifiedAt
    }

    init?(data: Data) {
        guard let raw = try? CanonicalJSON.decode(data),
              let object = raw.objectValue,
              let idString = object["id"]?.stringValue,
              let id = UUID(uuidString: idString) else { return nil }
        self.id = id
        self.noteId = (object["noteId"]?.stringValue).flatMap(UUID.init(uuidString:)) ?? id
        self.modifiedAt = (object["modifiedAt"]?.stringValue).flatMap(SyncTime.date) ?? Date()
        if let elementsValue = object["elements"] {
            let data = CanonicalJSON.encode(elementsValue)
            self.elements = (try? JSONDecoder().decode([DrawElement].self, from: data)) ?? []
        } else {
            self.elements = []
        }
        let known: Set<String> = ["id", "noteId", "elements", "modifiedAt", "schemaVersion"]
        self.extra = object.filter { !known.contains($0.key) }
    }

    func canonicalData() -> Data {
        var object = extra
        object["schemaVersion"] = .int(DrawingDocument.schemaVersion)
        object["id"] = .string(id.uuidString.lowercased())
        object["noteId"] = .string(noteId.uuidString.lowercased())
        object["modifiedAt"] = .string(SyncTime.string(modifiedAt))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let encoded = try? encoder.encode(elements),
           let value = try? CanonicalJSON.decode(encoded) {
            object["elements"] = value
        } else {
            object["elements"] = .array([])
        }
        return CanonicalJSON.encode(.object(object))
    }

    var drawing: Drawing {
        var d = Drawing()
        d.id = id
        d.elements = elements
        return d
    }

    static func fileName(for id: UUID) -> String { "\(id.uuidString.lowercased()).json" }
    static func recordKey(for id: UUID) -> String { "drawing:\(id.uuidString.lowercased())" }

    static func appProperties(noteId: UUID) -> [String: JSONValue] {
        [
            "entityType": .string("drawing"),
            "schemaVersion": .int(schemaVersion),
            "noteId": .string(noteId.uuidString.lowercased())
        ]
    }
}

// MARK: - Three-way merge

enum NoteMerge {
    enum Outcome: Equatable {
        /// Local never diverged from the base — take the server's version.
        case useRemote(NoteDocument)
        /// The server never diverged — keep what's here.
        case keepLocal
        /// Different fields changed on each side; combined without asking.
        case merged(NoteDocument)
        /// The same field changed differently. Local stays; the remote version
        /// is preserved as a separate note so neither side is lost.
        case conflict(local: NoteDocument, remote: NoteDocument)
    }

    /// `base` is the content this device last reconciled. Without it we can't
    /// tell "they changed it" from "I changed it", so we conservatively treat
    /// any difference as a conflict rather than guessing.
    static func merge(base: NoteDocument?, local: NoteDocument, remote: NoteDocument) -> Outcome {
        if local.body == remote.body && local.pinned == remote.pinned
            && local.emoji == remote.emoji && local.drawingIds == remote.drawingIds {
            return .keepLocal
        }

        guard let base else {
            return local.body == remote.body ? .keepLocal
                                             : .conflict(local: local, remote: remote)
        }

        let localChanged = local.body != base.body
        let remoteChanged = remote.body != base.body

        // Field-wise: whichever side moved a field away from the base wins it.
        var result = local
        result.pinned = local.pinned != base.pinned ? local.pinned : remote.pinned
        result.emoji = local.emoji != base.emoji ? local.emoji : remote.emoji
        result.drawingIds = local.drawingIds != base.drawingIds
            ? local.drawingIds : remote.drawingIds
        result.modifiedAt = max(local.modifiedAt, remote.modifiedAt)

        switch (localChanged, remoteChanged) {
        case (false, false):
            return result == local ? .keepLocal : .merged(result)
        case (false, true):
            result.body = remote.body
            return .useRemote(result)
        case (true, false):
            result.body = local.body
            return .merged(result)
        case (true, true):
            if local.body == remote.body {
                result.body = local.body
                return .merged(result)
            }
            // Same field, two different edits — never silently pick one.
            return .conflict(local: local, remote: remote)
        }
    }

    /// Materialises the losing side as its own note, so both survive on every
    /// device once it syncs back.
    static func conflictCopy(of remote: NoteDocument, deviceName: String) -> Note {
        var note = Note()
        note.id = UUID()
        note.created = remote.createdAt
        note.updated = Date()
        note.emoji = remote.emoji
        let banner = "> Conflicting version from \(deviceName). "
            + "Merge anything you need into the original, then delete this note.\n\n"
        note.text = banner + remote.body
        return note
    }
}
