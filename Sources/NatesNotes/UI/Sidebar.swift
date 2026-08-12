import SwiftUI

struct Sidebar: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var app: AppState

    private var locked: Bool { app.mode == .lockedIn }
    private var pinned: [Note] { store.filteredNotes.filter(\.pinned) }
    private var others: [Note] { store.filteredNotes.filter { !$0.pinned } }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                workspaceHeader
                quickLinks
                notesList
                Spacer(minLength: 0)
                newNoteButton
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // The divider carries a running light in Locked-In mode.
            LiveDivider(axis: .vertical, active: locked, period: 5.2, delay: 0.9)
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sSidebar)
    }

    // MARK: - Header

    private var workspaceHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "brain")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.sAccent)
            Text("My Mind")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.sTextPrimary)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.sTextFaint)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Quick links

    private struct QuickLink: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let filter: (Note) -> Bool
    }

    private var quickLinks: some View {
        VStack(spacing: 1) {
            let links: [QuickLink] = [
                QuickLink(icon: "tray", label: "Inbox") { _ in true },
                QuickLink(icon: "calendar", label: "Today") {
                    Calendar.current.isDateInToday($0.updated)
                },
                QuickLink(icon: "star", label: "Favorites") { $0.pinned }
            ]
            ForEach(links) { link in
                let count = store.notes.filter(link.filter).count
                SidebarRow(icon: link.icon, label: link.label, trailing: count > 0 ? "\(count)" : nil,
                           selected: false, accentDot: false) {
                    store.search = ""
                }
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: - Notes

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(store.search.isEmpty ? "Notes" : "Results")

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(pinned) { note in
                        noteRow(note)
                    }
                    if !pinned.isEmpty && !others.isEmpty {
                        Divider()
                            .overlay(Theme.sHairline)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                    }
                    ForEach(others) { note in
                        noteRow(note)
                    }

                    if store.filteredNotes.isEmpty {
                        Text("Nothing matches")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.sTextFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func noteRow(_ note: Note) -> some View {
        SidebarRow(icon: note.emoji.isEmpty ? (note.hasDrawing ? "scribble" : "doc.text") : nil,
                   emoji: note.emoji,
                   label: note.title,
                   trailing: nil,
                   selected: store.selectedID == note.id,
                   accentDot: note.pinned) {
            withAnimation(Motion.snappy) { store.selectedID = note.id }
        }
        .contextMenu {
            Button(note.pinned ? "Unpin" : "Pin") { store.togglePin(note.id) }
            Button("Duplicate") { store.duplicate(note.id) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [store.root.appendingPathComponent("\(note.id.uuidString).md")])
            }
            Divider()
            Button("Delete", role: .destructive) {
                withAnimation(Motion.spring) { store.delete(note.id) }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.14 * 9.5)
            .foregroundStyle(Theme.sTextFaint)
            .padding(.horizontal, 9)
            .padding(.bottom, 6)
    }

    private var newNoteButton: some View {
        Button {
            withAnimation(Motion.spring) { _ = store.newNote() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New Note")
                    .font(.system(size: 12.5))
                Spacer()
            }
            .foregroundStyle(Theme.sTextTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .help("New note — ⌘N")
    }
}

/// One sidebar line. The selection highlight slides rather than blinking, and
/// hover lifts it a hair — small motions, but they make the list feel physical.
private struct SidebarRow: View {
    var icon: String?
    var emoji: String = ""
    let label: String
    var trailing: String?
    let selected: Bool
    var accentDot: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    if !emoji.isEmpty {
                        Text(emoji).font(.system(size: 11.5))
                    } else if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(selected ? Theme.sAccent : Theme.sTextFaint)
                    }
                }
                .frame(width: 14)

                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.sTextPrimary : Theme.sTextSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if accentDot {
                    Circle()
                        .fill(Theme.sAccent)
                        .frame(width: 4, height: 4)
                }
                if let trailing {
                    Text(trailing)
                        .font(Font(Theme.mono(9.5)))
                        .foregroundStyle(Theme.sTextFaint)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.075))
                        // A thin accent edge marks the active note.
                        HStack {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Theme.sAccent)
                                .frame(width: 2, height: 13)
                            Spacer()
                        }
                        .padding(.leading, 1)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable(scale: 0.985)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: selected)
        .animation(Motion.fade, value: hovering)
    }
}

extension Note {
    var hasDrawing: Bool { !drawings.isEmpty }
}
