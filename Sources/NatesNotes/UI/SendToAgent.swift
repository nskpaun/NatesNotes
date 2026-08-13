import SwiftUI
import AppKit

/// The coding agents a note can be handed to.
enum CodingAgent: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    /// The CLI binary, resolved through the user's login shell.
    var command: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }
}

/// Launches an agent CLI in a fresh Terminal window.
enum AgentLauncher {

    /// Runs `agent` in `directory` with `prompt` as its opening instruction.
    ///
    /// The launch goes through a generated `.command` file, which Terminal
    /// opens like a document and executes — no Apple-events automation
    /// permission involved. `zsh -l` gives the script the user's login PATH,
    /// which is where `claude` and `codex` actually live (Homebrew, npm,
    /// `~/.local`). The prompt travels in a sidecar file and is spliced in
    /// with `"$(cat …)"`, so no amount of quoting inside the note can escape
    /// into the shell.
    static func launch(_ agent: CodingAgent, prompt: String, directory: URL) throws {
        let dir = try scratchDirectory()
        sweepStaleFiles(in: dir)

        let stamp = UUID().uuidString
        let promptFile = dir.appendingPathComponent("prompt-\(stamp).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        let script = """
        #!/bin/zsh -l
        cd \(shellQuoted(directory.path)) || exit 1
        exec \(agent.command) "$(cat \(shellQuoted(promptFile.path)))"

        """
        let runner = dir.appendingPathComponent("run-\(stamp).command")
        try script.write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: runner.path)
        NSWorkspace.shared.open(runner)
    }

    /// Whether the agent's binary resolves in a login shell — the same
    /// environment the runner script will get.
    static func isAvailable(_ agent: CodingAgent) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "command -v \(agent.command)"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NatesNotes/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Yesterday's prompts have no value; don't let them accumulate.
    private static func sweepStaleFiles(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}

/// Title-bar button that opens the send panel.
struct SendToAgentButton: View {
    @ObservedObject var store: NoteStore
    @State private var showPanel = false
    @State private var hovering = false

    var body: some View {
        Button { showPanel.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10.5, weight: .medium))
                Text("Send to agent")
                    .font(.system(size: 11.5))
                    .fixedSize()
            }
            .foregroundStyle(hovering ? Theme.sTextSecondary : Theme.sTextTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0.045))
            )
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .help("Hand a prompt — and this note — to Claude Code or Codex")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            SendToAgentPanel(store: store) { showPanel = false }
        }
    }
}

/// The panel: pick an agent, write a prompt, optionally attach the open note,
/// choose where the agent should run.
struct SendToAgentPanel: View {
    @ObservedObject var store: NoteStore
    var dismiss: () -> Void

    // Drafts survive the popover closing — nothing typed here is ever lost to
    // a stray click.
    @AppStorage("nn.agent.choice") private var agentRaw = CodingAgent.claudeCode.rawValue
    @AppStorage("nn.agent.draft") private var prompt = ""
    @AppStorage("nn.agent.workdir") private var workdir = NSHomeDirectory()
    @AppStorage("nn.agent.attachNote") private var attachNote = true

    @State private var availability: [CodingAgent: Bool] = [:]
    @State private var launchError: String?
    @FocusState private var promptFocused: Bool

    private var agent: CodingAgent { CodingAgent(rawValue: agentRaw) ?? .claudeCode }
    private var expandedWorkdir: String { (workdir as NSString).expandingTildeInPath }
    private var workdirExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expandedWorkdir, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
    private var canSend: Bool {
        let hasContent = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (attachNote && store.selected != nil)
        return hasContent && workdirExists && availability[agent] != false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $agentRaw) {
                ForEach(CodingAgent.allCases) { agent in
                    Text(agent.rawValue).tag(agent.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 92)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                    )
                    .focused($promptFocused)
                if prompt.isEmpty {
                    Text("What should \(agent.rawValue) do?")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sTextFaint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }

            if let note = store.selected {
                Toggle(isOn: $attachNote) {
                    Text("Attach “\(note.title)” as context")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.sTextSecondary)
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Run in")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.sTextFaint)
                TextField("~/path/to/project", text: $workdir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                if !workdirExists {
                    Text("That folder doesn't exist.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                if availability[agent] == false {
                    Text("`\(agent.command)` isn't on your shell's PATH.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                } else if let launchError {
                    Text(launchError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { promptFocused = true }
        .task {
            for agent in CodingAgent.allCases {
                availability[agent] = await AgentLauncher.isAvailable(agent)
            }
        }
    }

    /// A Terminal window opens on the chosen folder with the agent already
    /// reading the prompt; the note rides along underneath it.
    private func send() {
        var full = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachNote, let note = store.selected {
            if full.isEmpty {
                full = "Read the attached note and do what it describes."
            }
            full += "\n\n---\nAttached note “\(note.title)” from Nate's Notes:\n\n" + note.text
        }
        do {
            try AgentLauncher.launch(agent, prompt: full,
                                     directory: URL(fileURLWithPath: expandedWorkdir,
                                                    isDirectory: true))
            prompt = ""
            launchError = nil
            dismiss()
        } catch {
            launchError = error.localizedDescription
        }
    }
}
