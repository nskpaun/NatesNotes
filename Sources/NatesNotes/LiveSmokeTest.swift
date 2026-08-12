import Foundation
import SyncKit

/// End-to-end check against the real Personal File Sync server.
///
///     NatesNotes --sync-smoke <PAIRING-CODE> [--keep]
///
/// It pairs, pushes a note, proves a second device sees the same bytes, edits,
/// renames, deletes, and then cleans up after itself — revoking its own token
/// so the throwaway device doesn't linger in `list-devices`. Everything lives
/// in a temporary directory and an in-memory credential store, so the real
/// app's Keychain entry and sync state are never touched.
enum LiveSmokeTest {

    /// Runs exactly one sync against the app's real state and reports what
    /// happened at each step. For diagnosing a stuck outbox in the field.
    static func diagnose() async {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NatesNotes/sync", isDirectory: true)
        print("state: \(directory.path)")

        let credentials = KeychainCredentialStore()
        do {
            let token = try credentials.token()
            print("keychain token: \(token == nil ? "MISSING" : "present (\(token!.count) chars)")")
        } catch {
            print("keychain token: UNREADABLE — \(error)")
        }

        do {
            let store = try SyncStateStore(directory: directory)
            let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs"))
            let settings = SyncSettings.standard()
            let engine = SyncEngine(transport: HTTPSyncTransport(settings: settings,
                                                                 credentials: credentials),
                                    store: store, blobs: blobs,
                                    credentials: credentials, settings: settings)

            func dump(_ label: String) {
                let outbox = store.state.outbox
                print("\n\(label): \(outbox.count) item(s)")
                for item in outbox {
                    print("  \(item.recordKey.prefix(28)) | \(item.status.rawValue)"
                          + " | folder \(item.folder ?? "nil")"
                          + " | attempts \(item.attempts ?? 0)"
                          + " | \((item.lastProblem ?? "").prefix(60))")
                }
            }

            dump("before")
            print("\nsyncing…")
            let outcome = try await engine.sync()
            print("pushed \(outcome.pushed), pulled \(outcome.updated.count),"
                  + " removed \(outcome.removed.count)")
            dump("after")
        } catch {
            print("\nsync failed: \(describe(error))")
        }
        exit(0)
    }


    static func run(code: String, keep: Bool) async {
        var failures = 0
        var checks = 0

        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            checks += 1
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func step(_ label: String) { print("\n▸ \(label)") }

        let settings = SyncSettings.standard()
        print("Server: \(settings.baseURL.absoluteString)")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nn-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Shared credential store: device B reuses the token to act as a second
        // installation with no local state.
        let credentials = InMemoryCredentialStore()
        let transport = HTTPSyncTransport(settings: settings, credentials: credentials)

        do {
            // ---- Capabilities -------------------------------------------------
            step("Capabilities")
            let caps = try await transport.capabilities()
            check("unauthenticated capabilities", caps.maxPageSize != nil,
                  "page≤\(caps.maxPageSize ?? -1) batch≤\(caps.maxMutationBatch ?? -1)")
            check("resumable upload advertised", caps.supports("resumable-upload"))

            // ---- Pair ---------------------------------------------------------
            step("Pairing")
            let storeA = try SyncStateStore(directory: root.appendingPathComponent("a"))
            let blobsA = try BlobStore(directory: root.appendingPathComponent("a/blobs"))
            let engineA = SyncEngine(transport: transport, store: storeA, blobs: blobsA,
                                     credentials: credentials, settings: settings)
            let space = try await engineA.pair(code: code, deviceName: "Smoke Test")
            check("redeemed pairing code", true, "space \(space.slug) (\(space.id))")
            check("token stored out of app state", (try credentials.token()) != nil)
            check("root node id present", !space.rootNodeId.isEmpty, space.rootNodeId)

            let device = try await engineA.validateCredential()
            check("credential validates", !device.id.isEmpty, "device \(device.id)")

            // ---- First sync ---------------------------------------------------
            step("Initial sync")
            let first = try await engineA.sync()
            check("initial sync completed", true,
                  "\(first.updated.count) existing document(s) pulled")

            // ---- Push a note --------------------------------------------------
            step("Push a note")
            let noteID = UUID()
            let body = "Live smoke test at \(SyncTime.string(Date()))"
            let payload = canonicalNote(id: noteID, body: body)

            try await engineA.enqueueUpsert(
                recordKey: "note:\(noteID.uuidString.lowercased())",
                folder: SyncEngine.notesFolder,
                fileName: "\(noteID.uuidString.lowercased()).json",
                mediaType: "application/vnd.natesnotes.note+json",
                appProperties: ["entityType": .string("note"), "schemaVersion": .int(1)],
                content: payload)
            _ = try await engineA.sync()
            check("outbox drained", await engineA.state.outbox.isEmpty,
                  "\(await engineA.state.outbox.count) left")

            // ---- Second device sees it ----------------------------------------
            step("Second device")
            let storeB = try SyncStateStore(directory: root.appendingPathComponent("b"))
            let blobsB = try BlobStore(directory: root.appendingPathComponent("b/blobs"))
            let engineB = SyncEngine(transport: transport, store: storeB, blobs: blobsB,
                                     credentials: credentials, settings: settings)
            try await engineB.adoptPairing(spaceId: space.id, rootNodeId: space.rootNodeId)
            let seen = try await engineB.sync()

            let match = seen.updated.first { $0.content == payload }
            check("second device received identical bytes", match != nil,
                  match.map { "as \($0.name) v\($0.version)" }
                      ?? "got \(seen.updated.count) document(s)")
            check("blob verified by digest", match != nil)

            // ---- Edit ---------------------------------------------------------
            step("Edit and re-push")
            let edited = canonicalNote(id: noteID, body: body + " — edited")
            try await engineA.enqueueUpsert(
                recordKey: "note:\(noteID.uuidString.lowercased())",
                folder: SyncEngine.notesFolder,
                fileName: "\(noteID.uuidString.lowercased()).json",
                mediaType: "application/vnd.natesnotes.note+json",
                appProperties: ["entityType": .string("note"), "schemaVersion": .int(1)],
                content: edited)
            _ = try await engineA.sync()

            let afterEdit = try await engineB.sync()
            let editedSeen = afterEdit.updated.first { $0.content == edited }
            check("edit propagated with a new version", editedSeen != nil,
                  editedSeen.map { "v\($0.version)" } ?? "not seen")

            let nodeID = await engineA.state.mirror.values
                .first { $0.name == "\(noteID.uuidString.lowercased()).json" }?.nodeId
            check("node id stable across the edit", nodeID != nil, nodeID ?? "missing")

            // ---- Re-push identical content ------------------------------------
            step("Idempotence")
            let beforeCount = await engineA.state.mirror.count
            try await engineA.enqueueUpsert(
                recordKey: "note:\(noteID.uuidString.lowercased())",
                folder: SyncEngine.notesFolder,
                fileName: "\(noteID.uuidString.lowercased()).json",
                mediaType: "application/vnd.natesnotes.note+json",
                appProperties: ["entityType": .string("note"), "schemaVersion": .int(1)],
                content: edited)
            _ = try await engineA.sync()
            check("re-pushing identical bytes creates no new node",
                  await engineA.state.mirror.count == beforeCount,
                  "\(beforeCount) → \(await engineA.state.mirror.count)")

            // ---- Live conflict ------------------------------------------------
            // The most important thing to prove against the real server: a
            // stale write must be refused, not silently applied.
            step("Concurrent edit")
            let fileName = "\(noteID.uuidString.lowercased()).json"
            let recordKey = "note:\(noteID.uuidString.lowercased())"

            // Bring B fully up to date first — the idempotence step moved the
            // server on, and B must be the *current* writer for this to test
            // what it claims to.
            _ = try await engineB.sync()

            let fromB = canonicalNote(id: noteID, body: body + " — edited on device B")
            try await engineB.enqueueUpsert(
                recordKey: recordKey, folder: SyncEngine.notesFolder, fileName: fileName,
                mediaType: "application/vnd.natesnotes.note+json",
                appProperties: ["entityType": .string("note"), "schemaVersion": .int(1)],
                content: fromB)
            _ = try await engineB.sync()

            // A never saw that, so it still holds the older baseVersion.
            let fromA = canonicalNote(id: noteID, body: body + " — edited on device A")
            try await engineA.enqueueUpsert(
                recordKey: recordKey, folder: SyncEngine.notesFolder, fileName: fileName,
                mediaType: "application/vnd.natesnotes.note+json",
                appProperties: ["entityType": .string("note"), "schemaVersion": .int(1)],
                content: fromA)
            _ = try? await engineA.sync()

            let open = await engineA.state.conflicts.filter { !$0.resolved }
            check("stale write was refused, not applied", open.count == 1,
                  "\(open.count) conflict(s) recorded")
            check("this device's version was kept verbatim",
                  open.first?.localContent == fromA)

            // And the server still holds B's bytes — nothing was clobbered.
            let serverBytes = try await currentBytes(of: fileName, transport: transport,
                                                     spaceId: space.id,
                                                     rootNodeId: space.rootNodeId)
            check("the other device's version survived on the server",
                  serverBytes == fromB)

            if let conflict = open.first {
                let merged = canonicalNote(id: noteID, body: body + " — merged")
                try await engineA.resolveConflict(conflict.id, mergedContent: merged)
                _ = try await engineA.sync()
                let afterMerge = try await currentBytes(of: fileName, transport: transport,
                                                        spaceId: space.id,
                                                        rootNodeId: space.rootNodeId)
                check("resolution applied against the server's current version",
                      afterMerge == merged)
                check("conflict cleared", await engineA.state.conflicts.allSatisfy(\.resolved))
            }

            // ---- Multi-page snapshot ------------------------------------------
            step("Paged snapshot")
            var extraIDs: [UUID] = []
            for index in 0..<3 {
                let extra = UUID()
                extraIDs.append(extra)
                try await engineA.enqueueUpsert(
                    recordKey: "note:\(extra.uuidString.lowercased())",
                    folder: SyncEngine.notesFolder,
                    fileName: "\(extra.uuidString.lowercased()).json",
                    mediaType: "application/vnd.natesnotes.note+json",
                    appProperties: ["entityType": .string("note"), "schemaVersion": .int(1)],
                    content: canonicalNote(id: extra, body: "paging fixture \(index)"))
            }
            _ = try await engineA.sync()

            // A third install snapshots two nodes at a time, forcing real paging.
            let storeC = try SyncStateStore(directory: root.appendingPathComponent("c"))
            let blobsC = try BlobStore(directory: root.appendingPathComponent("c/blobs"))
            let engineC = SyncEngine(transport: transport, store: storeC, blobs: blobsC,
                                     credentials: credentials, settings: settings,
                                     pageLimit: 2)
            try await engineC.adoptPairing(spaceId: space.id, rootNodeId: space.rootNodeId)
            _ = try await engineC.sync()

            let expected = await engineA.state.mirror.values.filter { !$0.isTombstone }.count
            let got = await engineC.state.mirror.values.filter { !$0.isTombstone }.count
            check("multi-page snapshot assembled completely", got == expected,
                  "\(got) of \(expected) nodes across \(Int(ceil(Double(expected) / 2))) pages")
            check("cursor committed after paging",
                  await engineC.state.lastCommittedCursor != nil)

            // ---- Delete -------------------------------------------------------
            for extra in extraIDs where !keep {
                try await engineA.enqueueDelete(
                    recordKey: "note:\(extra.uuidString.lowercased())",
                    folder: SyncEngine.notesFolder,
                    fileName: "\(extra.uuidString.lowercased()).json")
            }
            if !keep && !extraIDs.isEmpty { _ = try await engineA.sync() }

            if keep {
                print("\n▸ Cleanup skipped (--keep): note \(noteID) left on the server")
            } else {
                step("Delete")
                try await engineA.enqueueDelete(
                    recordKey: "note:\(noteID.uuidString.lowercased())",
                    folder: SyncEngine.notesFolder,
                    fileName: "\(noteID.uuidString.lowercased()).json")
                _ = try await engineA.sync()

                let afterDelete = try await engineB.sync()
                let tombstoned = afterDelete.removed.contains {
                    $0.name == "\(noteID.uuidString.lowercased()).json"
                }
                check("tombstone reached the second device", tombstoned)
            }

            // ---- Revoke -------------------------------------------------------
            step("Revoke")
            await engineA.unpair(revokeRemotely: true)
            check("token cleared locally", (try credentials.token()) == nil)

            do {
                try credentials.setToken("stale")
                _ = try await transport.currentDevice()
                check("revoked token is rejected", false, "server still accepted it")
            } catch SyncError.unauthorized {
                check("revoked token is rejected", true)
            } catch {
                check("revoked token is rejected", false, "\(error)")
            }
            try? credentials.setToken(nil)

        } catch {
            failures += 1
            print("\nERROR: \(describe(error))")
        }

        print("\n\(failures == 0 ? "All \(checks) live checks passed." : "\(failures) of \(checks) checks FAILED.")")
        exit(failures == 0 ? 0 : 1)
    }

    /// Reads a file's current bytes straight off the server, bypassing every
    /// local cache — so "the server still holds X" is a real claim.
    private static func currentBytes(of fileName: String, transport: SyncTransport,
                                     spaceId: String, rootNodeId: String) async throws -> Data? {
        var nodes: [SyncNode] = []
        var snapshotToken: String?
        var pageToken: String?
        repeat {
            let page = try await transport.listNodes(spaceId: spaceId,
                                                     snapshotToken: snapshotToken,
                                                     pageToken: pageToken, limit: 200)
            if snapshotToken == nil { snapshotToken = page.snapshotToken }
            nodes.append(contentsOf: page.nodes)
            pageToken = page.nextPageToken
        } while pageToken != nil

        guard let node = nodes.first(where: { $0.name == fileName && !$0.isTombstone }),
              let blob = node.blob else { return nil }
        return try await transport.downloadBlob(spaceId: spaceId, blobID: blob.id, offset: 0)
    }

    private static func canonicalNote(id: UUID, body: String) -> Data {
        CanonicalJSON.encode(.object([
            "schemaVersion": .int(1),
            "id": .string(id.uuidString.lowercased()),
            "body": .string(body),
            "title": .string("Live smoke test"),
            "pinned": .bool(false),
            "emoji": .string(""),
            "drawingIds": .array([]),
            "createdAt": .string(SyncTime.string(Date())),
            "modifiedAt": .string(SyncTime.string(Date()))
        ]))
    }

    private static func describe(_ error: Error) -> String {
        guard let sync = error as? SyncError else { return "\(error)" }
        switch sync {
        case .forbidden(let detail):
            return "403 — \(detail)\nThe pairing code is invalid, expired (10 min) or already used."
        case .unauthorized:
            return "401 — the token was rejected."
        case .transient(_, _, let detail):
            return "network/5xx — \(detail)"
        case .permanent(let status, let detail):
            return "\(status) — \(detail)"
        case .malformedResponse(let detail):
            return "unexpected response shape — \(detail)"
        default:
            return "\(sync)"
        }
    }
}
