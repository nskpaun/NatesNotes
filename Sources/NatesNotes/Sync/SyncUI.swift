import SwiftUI
import SyncKit

/// Compact status pill in the sidebar footer; opens the sync popover.
struct SyncStatusButton: View {
    @ObservedObject var sync: SyncController
    @State private var showPanel = false

    var body: some View {
        Button { showPanel.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.sTextTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sync")
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            SyncPanel(sync: sync)
        }
    }

    private var tint: Color {
        switch sync.status {
        case .idle: return sync.pendingCount > 0 ? Theme.sAccent : .green
        case .syncing: return .blue
        case .offline: return .orange
        case .unpaired: return Theme.sTextTertiary
        case .needsPairing, .failed: return .red
        }
    }

    private var label: String {
        switch sync.status {
        case .unpaired: return "Not synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .needsPairing: return "Pair again"
        case .failed: return "Sync error"
        case .idle:
            // Deliberately no count: unsent edits are the app's problem to
            // solve, not a number for the user to watch.
            if sync.pendingCount > 0 { return "Saving…" }
            guard let at = sync.lastSyncedAt else { return "Synced" }
            return "Synced \(at.shortRelative)"
        }
    }
}

/// The sync popover: pairing, state, conflicts.
struct SyncPanel: View {
    @ObservedObject var sync: SyncController
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var server = ""
    @State private var editingServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sync")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sTextPrimary)
                Spacer()
                if case .syncing = sync.status {
                    ProgressView().controlSize(.small)
                }
            }

            serverField

            switch sync.status {
            case .unpaired, .needsPairing:
                pairingForm
            default:
                pairedBody
            }

            if !sync.conflicts.isEmpty {
                Divider()
                conflictSection
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(isError ? .red : Theme.sTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// The server address lives here rather than in source, so the repository
    /// never carries a personal endpoint.
    private var serverField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Server")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.sTextFaint)
                Spacer()
                if !editingServer {
                    Button("Change") { editingServer = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.sAccent)
                }
            }
            if editingServer {
                HStack(spacing: 6) {
                    TextField("https://…", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { saveServer() }
                    Button("Save") { saveServer() }
                }
            } else {
                Text(sync.serverDescription)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.sTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onAppear { server = sync.serverDescription }
    }

    private func saveServer() {
        sync.setServer(server)
        editingServer = false
        message = "Server set. Pair this device to start syncing."
        isError = false
    }

    // MARK: Pairing

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter a one-time pairing code from your sync server to sync this Mac's notes.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.sTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .needsPairing(let detail) = sync.status {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                TextField("PAIRING-CODE", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { submit() }
                Button("Pair") { submit() }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }

            Text("Codes expire after 10 minutes and work once.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.sTextTertiary)
        }
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        message = nil
        Task {
            let result = await sync.pair(code: trimmed)
            busy = false
            switch result {
            case .success(let space):
                code = ""
                isError = false
                message = "Paired with \(space)."
            case .failure(let error):
                isError = true
                message = SyncController.describe(error)
            }
        }
    }

    // MARK: Paired

    private var pairedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Device", sync.deviceName)
            row("Queued", sync.pendingCount == 0 ? "Nothing pending" : "\(sync.pendingCount) change\(sync.pendingCount == 1 ? "" : "s")")
            if let at = sync.lastSyncedAt {
                row("Last sync", at.shortRelative)
            }
            if case .offline(let detail) = sync.status {
                Text(detail + " — local edits are queued and will send when it's reachable.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let detail) = sync.status {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Sync now") {
                    Task { await sync.syncNow(reason: "manual") }
                }
                Spacer()
                Button("Unpair") {
                    Task { await sync.unpair() }
                }
                .foregroundStyle(.red)
            }
            .padding(.top, 2)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.sTextTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.sTextSecondary)
        }
    }

    // MARK: Conflicts

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(sync.conflicts.count) conflict\(sync.conflicts.count == 1 ? "" : "s")",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
            Text("Both versions are kept. Nothing has been overwritten.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.sTextTertiary)

            ForEach(sync.conflicts, id: \.id) { conflict in
                HStack(spacing: 6) {
                    Text(conflict.recordKey.hasPrefix("note:") ? "Note" : "Drawing")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sTextSecondary)
                    Spacer()
                    Button("Keep mine") { sync.resolveKeepingLocal(conflict) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sAccent)
                    Button("Take theirs") { sync.resolveTakingRemote(conflict) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sTextSecondary)
                }
            }
        }
    }
}

/// In-note banner when this note specifically is conflicted.
struct ConflictBanner: View {
    @ObservedObject var sync: SyncController
    let noteID: UUID

    private var conflict: ConflictRecord? {
        sync.conflicts.first { $0.recordKey == NoteDocument.recordKey(for: noteID) }
    }

    var body: some View {
        if let conflict {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Also edited on another device. Both versions are kept.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.sTextSecondary)
                Spacer()
                Button("Keep mine") { sync.resolveKeepingLocal(conflict) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.sAccent)
                Button("Take theirs") { sync.resolveTakingRemote(conflict) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.sTextSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.sHairline).frame(height: 1)
            }
        }
    }
}
