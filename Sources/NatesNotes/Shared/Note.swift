import Foundation

struct Note: Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String = ""
    var created: Date = Date()
    var updated: Date = Date()
    var pinned: Bool = false
    var emoji: String = ""
    /// Drawings embedded in this note, keyed by the id referenced from markdown.
    var drawings: [UUID: Drawing] = [:]

    /// Title is derived from the first non-empty line — no separate title field to
    /// keep in sync, which is what makes the "just start typing" flow work.
    var title: String {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "*", with: "")
                       .replacingOccurrences(of: "`", with: "")
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { line = String(line.dropFirst(6)) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            if line.isEmpty { continue }
            return String(line.prefix(120))
        }
        return "Untitled"
    }

    /// Second meaningful line, used as the list subtitle.
    var preview: String {
        var seenTitle = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !seenTitle { seenTitle = true; continue }
            if line.hasPrefix("---") { continue }
            var s = line
            while s.hasPrefix("#") || s.hasPrefix(">") { s.removeFirst() }
            s = s.replacingOccurrences(of: "**", with: "")
                 .replacingOccurrences(of: "`", with: "")
                 .trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if s.hasPrefix("![](drawing://") { return "Drawing" }
            return String(s.prefix(160))
        }
        return "No additional text"
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}

// MARK: - On-disk representation

extension Note {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Markdown with a small YAML front matter block, so the files stay readable
    /// and portable to any other markdown tool.
    func serialized() -> String {
        var fm = "---\n"
        fm += "id: \(id.uuidString)\n"
        fm += "created: \(Note.iso.string(from: created))\n"
        fm += "updated: \(Note.iso.string(from: updated))\n"
        if pinned { fm += "pinned: true\n" }
        if !emoji.isEmpty { fm += "emoji: \(emoji)\n" }
        fm += "---\n\n"
        return fm + text
    }

    static func parse(_ raw: String, fallbackID: UUID) -> Note {
        var note = Note(id: fallbackID)
        guard raw.hasPrefix("---\n") else {
            note.text = raw
            return note
        }
        let rest = raw.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else {
            note.text = raw
            return note
        }
        let header = String(rest[rest.startIndex..<end.lowerBound])
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }

        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "id":      note.id = UUID(uuidString: value) ?? fallbackID
            case "created": note.created = iso.date(from: value) ?? Date()
            case "updated": note.updated = iso.date(from: value) ?? Date()
            case "pinned":  note.pinned = (value == "true")
            case "emoji":   note.emoji = value
            default: break
            }
        }
        note.text = body
        return note
    }
}
