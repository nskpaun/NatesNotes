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
            // Both bodies moved. Different lines are still independent changes
            // — a note is edited top and bottom from two devices far more often
            // than the same sentence is — so merge line-wise and only escalate
            // when the same region truly diverged.
            if let combined = mergeBodies(base: base.body, local: local.body,
                                          remote: remote.body) {
                result.body = combined
                return .merged(result)
            }
            return .conflict(local: local, remote: remote)
        }
    }

    // MARK: Line-level body merge

    /// One side's rewrite of a stretch of base lines. An empty `range` is an
    /// insertion before line `range.lowerBound`.
    private struct Hunk {
        var range: Range<Int>
        var lines: [Substring]
    }

    private struct SideHunk {
        var hunk: Hunk
        var isLocal: Bool
    }

    /// diff3 over lines: both sides' edits apply where they touched different
    /// regions of the note; `nil` only where the same lines truly diverged.
    ///
    /// Newline-preserving by construction — splitting keeps empty subsequences,
    /// so text round-trips exactly when there is nothing to merge.
    static func mergeBodies(base: String, local: String, remote: String) -> String? {
        let baseLines = base.split(separator: "\n", omittingEmptySubsequences: false)
        let localLines = local.split(separator: "\n", omittingEmptySubsequences: false)
        let remoteLines = remote.split(separator: "\n", omittingEmptySubsequences: false)

        // The LCS tables are quadratic; past this, a conflict copy is cheaper
        // than the merge attempt.
        guard baseLines.count * localLines.count <= 1_500_000,
              baseLines.count * remoteLines.count <= 1_500_000 else { return nil }

        let tagged = (hunks(base: baseLines, side: localLines).map { SideHunk(hunk: $0, isLocal: true) }
            + hunks(base: baseLines, side: remoteLines).map { SideHunk(hunk: $0, isLocal: false) })
            .sorted { a, b in
                if a.hunk.range.lowerBound != b.hunk.range.lowerBound {
                    return a.hunk.range.lowerBound < b.hunk.range.lowerBound
                }
                // An insertion sorts ahead of a rewrite starting at the same
                // line: it references content before that line.
                return a.hunk.range.count < b.hunk.range.count
            }

        // Group hunks whose base ranges genuinely interleave. Touching at a
        // boundary is composition, not conflict — an insertion right before a
        // rewritten block belongs to both sides at once only when it lands
        // *inside* the block.
        var merged: [Hunk] = []
        var index = 0
        while index < tagged.count {
            var cluster = [tagged[index]]
            var union = tagged[index].hunk.range
            var next = index + 1
            while next < tagged.count {
                let candidate = tagged[next].hunk.range
                let overlaps: Bool
                if candidate.isEmpty {
                    overlaps = union.isEmpty
                        ? candidate.lowerBound == union.lowerBound
                        : union.lowerBound < candidate.lowerBound
                            && candidate.lowerBound < union.upperBound
                } else {
                    overlaps = candidate.lowerBound < union.upperBound
                }
                guard overlaps else { break }
                cluster.append(tagged[next])
                union = union.lowerBound..<max(union.upperBound, candidate.upperBound)
                next += 1
            }
            index = next

            let ours = cluster.filter(\.isLocal).map(\.hunk)
            let theirs = cluster.filter { !$0.isLocal }.map(\.hunk)
            if ours.isEmpty || theirs.isEmpty {
                merged.append(contentsOf: cluster.map(\.hunk))
            } else {
                // Both sides rewrote this region. Identical rewrites — the
                // same fix made twice — collapse to one; anything else is a
                // real conflict.
                let mine = render(base: baseLines, range: union, hunks: ours)
                let other = render(base: baseLines, range: union, hunks: theirs)
                guard mine == other else { return nil }
                merged.append(Hunk(range: union, lines: mine))
            }
        }

        var output: [Substring] = []
        var cursor = 0
        for hunk in merged {
            output.append(contentsOf: baseLines[cursor..<hunk.range.lowerBound])
            output.append(contentsOf: hunk.lines)
            cursor = max(cursor, hunk.range.upperBound)
        }
        output.append(contentsOf: baseLines[cursor...])
        return output.joined(separator: "\n")
    }

    /// Difference between `base` and `side` as replacement hunks, via a
    /// longest-common-subsequence walk.
    private static func hunks(base: [Substring], side: [Substring]) -> [Hunk] {
        let n = base.count, m = side.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = base[i] == side[j]
                        ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var result: [Hunk] = []
        var pendingBase = 0, pendingSide = 0
        func flush(upTo i: Int, _ j: Int) {
            if pendingBase < i || pendingSide < j {
                result.append(Hunk(range: pendingBase..<i, lines: Array(side[pendingSide..<j])))
            }
        }

        var i = 0, j = 0
        while i < n && j < m {
            if base[i] == side[j] {
                flush(upTo: i, j)
                i += 1; j += 1
                pendingBase = i; pendingSide = j
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        flush(upTo: n, m)
        return result
    }

    /// What base lines `range` become after applying one side's hunks.
    private static func render(base: [Substring], range: Range<Int>,
                               hunks: [Hunk]) -> [Substring] {
        var out: [Substring] = []
        var cursor = range.lowerBound
        for hunk in hunks {
            if hunk.range.lowerBound > cursor {
                out.append(contentsOf: base[cursor..<hunk.range.lowerBound])
            }
            out.append(contentsOf: hunk.lines)
            cursor = max(cursor, hunk.range.upperBound)
        }
        if cursor < range.upperBound {
            out.append(contentsOf: base[cursor..<range.upperBound])
        }
        return out
    }

    static let conflictBanner = "> Conflicting version from another device. "
        + "Merge anything you need into the original, then delete this note.\n\n"

    /// The id a conflict copy of `source` always takes.
    ///
    /// Derived rather than fresh so a record can only ever own one outstanding
    /// copy. A fresh id per detection meant a record that kept conflicting —
    /// which is exactly what a record under active editing does — minted a new
    /// note on every sync pass, and each of those propagated as its own record.
    static func conflictCopyId(for source: UUID) -> UUID {
        var bytes = source.uuid
        // Fixed namespace twist: stable, and can't collide with the source.
        bytes.0 ^= 0x4E; bytes.1 ^= 0x43; bytes.2 ^= 0x4F; bytes.3 ^= 0x50
        return UUID(uuid: bytes)
    }

    /// Materialises the losing side as its own note, so both survive on every
    /// device once it syncs back.
    static func conflictCopy(of remote: NoteDocument, source: UUID) -> Note {
        var note = Note()
        note.id = conflictCopyId(for: source)
        note.created = remote.createdAt
        note.updated = Date()
        note.emoji = remote.emoji
        note.text = conflictBanner + remote.body
        return note
    }

    /// True while a copy is still exactly as this app wrote it, so refreshing it
    /// with a newer server version can't discard anything the user typed there.
    static func isUntouchedConflictCopy(_ note: Note) -> Bool {
        note.text.hasPrefix(conflictBanner)
    }
}

extension Note {
    /// A conflict copy that still carries its banner. Deleting the banner is
    /// how a note stops being one — that's the user saying "this is mine now".
    var isConflictCopy: Bool { text.hasPrefix(NoteMerge.conflictBanner) }
}
