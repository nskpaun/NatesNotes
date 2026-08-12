import SwiftUI

/// ⌘K overlay. Rows spring in on a stagger, and the selection highlight slides
/// between them with a matched-geometry effect rather than cutting.
struct CommandPalette: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var app: AppState
    var onNewSketch: () -> Void

    @State private var selection = 0
    @FocusState private var focused: Bool
    @Namespace private var highlight

    private struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let hint: String
        let isAction: Bool
        let run: () -> Void
    }

    private var results: [Row] {
        let query = app.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let notes = (query.isEmpty ? store.sortedNotes
                                   : store.sortedNotes.filter {
                                       $0.title.lowercased().contains(query)
                                           || $0.text.lowercased().contains(query)
                                   })
            .prefix(6)
            .map { note in
                Row(icon: note.hasDrawing ? "scribble" : "doc.text",
                    title: note.title,
                    hint: note.updated.shortRelative,
                    isAction: false) {
                    store.selectedID = note.id
                    app.closePalette()
                }
            }

        var actions: [Row] = [
            Row(icon: "square.and.pencil", title: "New note", hint: "⌘N", isAction: true) {
                store.newNote()
                app.closePalette()
            },
            Row(icon: "scribble.variable", title: "New sketch in this note",
                hint: "⇧⌘D", isAction: true) {
                app.closePalette()
                onNewSketch()
            },
            Row(icon: app.mode.symbol,
                title: "Switch to \(app.mode.toggled.shortLabel)", hint: "⇧⌘M", isAction: true) {
                app.closePalette()
                app.toggleMode()
            }
        ]
        if !query.isEmpty {
            actions = actions.filter { $0.title.lowercased().contains(query) }
        }
        return Array(notes) + actions
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Scrim: tap anywhere to dismiss.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { app.closePalette() }

            palette
                .padding(.top, 120)
        }
        .transition(.opacity)
    }

    private var palette: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(Theme.sHairline)
            rows
        }
        .frame(width: 580)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.sRaised)
                .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .transition(.asymmetric(
            insertion: .scale(scale: 0.95, anchor: .top)
                .combined(with: .offset(y: -14))
                .combined(with: .opacity),
            removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)))
        .onAppear { focused = true; selection = 0 }
        .onChange(of: app.paletteQuery) { _ in selection = 0 }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sTextFaint)
            TextField("Search notes and actions", text: $app.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.sTextPrimary)
                .focused($focused)
                .onSubmit { runSelection() }
            Text("esc")
                .font(Font(Theme.mono(9.5)))
                .foregroundStyle(Theme.sTextFaint)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 14)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                if index == 0 || (results[index - 1].isAction != row.isAction) {
                    Text(row.isAction ? "Actions" : "Notes")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.sTextFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 4 : 10)
                        .padding(.bottom, 3)
                }

                PaletteRow(icon: row.icon, title: row.title, hint: row.hint,
                           selected: index == selection,
                           namespace: highlight,
                           action: row.run)
                    .riseIn(index)
                    .onHover { if $0 { selection = index } }
            }
        }
        .padding(8)
        .animation(Motion.snappy, value: selection)
    }

    private func runSelection() {
        guard results.indices.contains(selection) else { return }
        results[selection].run()
    }

    /// Arrow-key navigation, wired from the hosting view's key handler.
    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }
}

private struct PaletteRow: View {
    let icon: String
    let title: String
    let hint: String
    let selected: Bool
    var namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.sAccent : Theme.sTextTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.sTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sTextFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.sAccent.opacity(0.16))
                        .matchedGeometryEffect(id: "paletteHighlight", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
