import SwiftUI
import SyncKit

/// Status vocabulary shared with the list's toolbar button.
extension SyncController {
    var statusSymbol: String {
        switch status {
        case .unpaired:     return "icloud.slash"
        case .idle:         return conflicts.isEmpty ? "checkmark.icloud" : "exclamationmark.icloud"
        case .syncing:      return "arrow.triangle.2.circlepath.icloud"
        case .offline:      return "icloud.slash"
        case .needsPairing: return "exclamationmark.icloud"
        case .failed:       return "exclamationmark.icloud"
        }
    }

    var statusTint: PlatformColor {
        switch status {
        case .idle:                      return conflicts.isEmpty ? Theme.accent : Theme.codeText
        case .syncing:                   return Theme.accent
        case .unpaired, .offline:        return Theme.textTertiary
        case .needsPairing, .failed:     return Theme.codeText
        }
    }

    var statusText: String {
        switch status {
        case .unpaired:              return "Not syncing"
        case .idle:                  return pendingCount > 0 ? "Saving…" : "Synced"
        case .syncing:               return "Saving…"
        case .offline(let why):      return why
        case .needsPairing(let why): return why
        case .failed(let why):       return why
        }
    }
}

struct SyncSheet: View {
    @EnvironmentObject private var sync: SyncController
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var server = ""
    @State private var working = false
    @State private var message: String?

    private var isPaired: Bool {
        if case .unpaired = sync.status { return false }
        if case .needsPairing = sync.status { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("This device", value: sync.deviceName)
                    LabeledContent("State", value: sync.statusText)
                    if let last = sync.lastSyncedAt {
                        LabeledContent("Last synced",
                                       value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if !sync.conflicts.isEmpty {
                        LabeledContent("Conflicts", value: "\(sync.conflicts.count)")
                            .foregroundStyle(Color(Theme.codeText))
                    }
                }

                if !isPaired {
                    Section {
                        TextField("sync.example.com", text: $server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Use this server") {
                            sync.setServer(server)
                            server = ""
                        }
                        .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Server")
                    } footer: {
                        Text("Currently \(sync.serverDescription). The address is kept "
                             + "on this iPhone, not built into the app.")
                    }

                    Section {
                        TextField("PAIRING-CODE", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button(working ? "Pairing…" : "Pair this iPhone") {
                            Task { await pair() }
                        }
                        .disabled(code.isEmpty || working)
                    } header: {
                        Text("Pair")
                    } footer: {
                        Text("Paste a one-time code from your sync server.")
                    }
                } else {
                    Section {
                        Button("Sync now") {
                            Task { await sync.syncNow(reason: "manual") }
                        }
                        Button("Unpair this iPhone", role: .destructive) {
                            Task { await sync.unpair() }
                        }
                    } footer: {
                        Text("Unpairing leaves every note on this iPhone untouched.")
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(Color(Theme.codeText)) }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func pair() async {
        working = true
        defer { working = false }
        switch await sync.pair(code: code.trimmingCharacters(in: .whitespaces)) {
        case .success(let space):
            message = "Paired with \(space)."
            code = ""
        case .failure(let error):
            message = SyncController.describe(error)
        }
    }
}
