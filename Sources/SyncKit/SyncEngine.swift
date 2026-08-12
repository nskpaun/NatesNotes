import Foundation

/// What the engine hands back to the app after a cycle, so the app can
/// reconcile remote content into its own storage.
public struct SyncOutcome: Sendable, Equatable {
    /// Nodes whose content changed remotely, with verified bytes.
    public var updated: [RemoteDocument] = []
    /// Records the server says are gone.
    public var removed: [RemoteTombstone] = []
    /// Clashes needing app-level merge; both sides preserved.
    public var conflicts: [ConflictRecord] = []
    public var pushed: Int = 0
    public var isEmpty: Bool { updated.isEmpty && removed.isEmpty && conflicts.isEmpty }
}

public struct RemoteDocument: Sendable, Equatable {
    public var nodeId: String
    public var name: String
    public var folder: String
    public var mediaType: String?
    public var appProperties: [String: JSONValue]
    public var content: Data
    public var version: Int
    /// Content this client last reconciled — the base for a three-way merge.
    public var base: Data?
}

public struct RemoteTombstone: Sendable, Equatable {
    public var nodeId: String
    public var name: String
    public var folder: String
}

public enum SyncPhase: String, Sendable {
    case idle, pairing, snapshotting, pushing, pulling, error
}

/// Serialises every operation against one space.
///
/// Being an actor is what makes the cursor and outbox transactions safe: no two
/// cycles can interleave, which the handoff requires ("serialize sync per space
/// or otherwise make cursor/outbox transactions concurrency-safe").
public actor SyncEngine {

    private let transport: SyncTransport
    private let store: SyncStateStore
    private let blobs: BlobStore
    private let credentials: CredentialStore
    private let settings: SyncSettings
    private let retry: RetryPolicy
    private let pageLimit: Int

    /// Folder names this app owns inside its space.
    public static let notesFolder = "notes"
    public static let drawingsFolder = "drawings"

    public private(set) var phase: SyncPhase = .idle

    /// Fetched once per session; the engine stays inside these limits.
    private var limits: ServerCapabilities?

    private var effectivePageLimit: Int {
        min(pageLimit, limits?.maxPageSize ?? pageLimit)
    }

    private var effectiveBatchSize: Int {
        min(50, limits?.maxMutationBatch ?? 50)
    }

    /// Best-effort: a deployment that doesn't answer still syncs with defaults.
    private func loadCapabilitiesIfNeeded() async {
        guard limits == nil else { return }
        limits = try? await transport.capabilities()
    }

    public init(transport: SyncTransport, store: SyncStateStore, blobs: BlobStore,
                credentials: CredentialStore, settings: SyncSettings,
                retry: RetryPolicy = RetryPolicy(), pageLimit: Int = 200) {
        self.transport = transport
        self.store = store
        self.blobs = blobs
        self.credentials = credentials
        self.settings = settings
        self.retry = retry
        self.pageLimit = pageLimit
    }

    public var state: SyncState { store.state }
    public var isPaired: Bool { store.state.isPaired && ((try? credentials.token()) ?? nil) != nil }

    // MARK: - Pairing

    /// Redeems a one-time code. The token goes straight to the credential store
    /// and is never returned to callers or written into `SyncState`.
    @discardableResult
    public func pair(code: String, deviceName: String) async throws -> SyncSpace {
        phase = .pairing
        defer { if phase == .pairing { phase = .idle } }

        let installationId = store.state.installationId
        let request = PairingRequest(code: code,
                                     deviceName: deviceName,
                                     deviceId: installationId,
                                     platform: settings.platform,
                                     appId: settings.appId,
                                     appVersion: settings.appVersion)
        // A bad code is 403 and must not be retried blindly, so only transient
        // failures get another attempt.
        let result = try await withRetry(policy: retry) {
            try await self.transport.redeemPairing(request)
        }

        guard let space = result.spaces.first(where: { $0.slug == settings.spaceSlug })
                ?? result.spaces.first else {
            throw SyncError.malformedResponse("pairing returned no spaces")
        }

        try credentials.setToken(result.token)
        try store.mutate { state in
            state.spaceId = space.id
            state.rootNodeId = space.rootNodeId
            state.deviceId = result.device.id
            state.deviceName = result.device.name ?? deviceName
            // A new pairing means a new server view; start from a fresh snapshot.
            state.lastCommittedCursor = nil
            state.mirror = [:]
        }
        return space
    }

    /// Attaches to an already-paired space with empty local state — how a
    /// restored install (or the live smoke test's "second device") starts from
    /// a snapshot rather than a fresh pairing.
    public func adoptPairing(spaceId: String, rootNodeId: String) throws {
        try store.mutate { state in
            state.spaceId = spaceId
            state.rootNodeId = rootNodeId
            state.lastCommittedCursor = nil
            state.mirror = [:]
        }
    }

    /// Confirms the stored credential is still good.
    public func validateCredential() async throws -> SyncDevice {
        try await withRetry(policy: retry) { try await self.transport.currentDevice() }
    }

    /// Revoke locally and server-side. Local notes are never touched.
    public func unpair(revokeRemotely: Bool = true) async {
        if revokeRemotely { try? await transport.revokeCurrentDevice() }
        try? credentials.setToken(nil)
        try? store.resetPairing()
        phase = .idle
    }

    // MARK: - The cycle

    /// record intent → push blobs → push mutations → pull changes → resolve → ack.
    @discardableResult
    public func sync() async throws -> SyncOutcome {
        guard store.state.isPaired else { throw SyncError.notPaired }
        guard ((try? credentials.token()) ?? nil) != nil else { throw SyncError.notPaired }

        var outcome = SyncOutcome()
        do {
            await loadCapabilitiesIfNeeded()
            // A snapshot populates the mirror but carries no bytes, so on the
            // first sync we also hand the app every existing file. Without this
            // a device pairing into a populated space would show nothing.
            var isFirstSync = false
            if store.state.lastCommittedCursor == nil {
                try await takeSnapshot()
                isFirstSync = true
            }
            try await ensureFolders()
            outcome.pushed = try await pushOutbox()
            if isFirstSync {
                outcome.updated = try await materialiseWholeMirror()
            }
            let pulled = try await pullChanges()
            // The fresh snapshot leaves nothing for the change feed to repeat,
            // so these can't collide.
            outcome.updated.append(contentsOf: pulled.updated)
            outcome.removed = pulled.removed
            outcome.conflicts = store.state.conflicts.filter { !$0.resolved }
            try store.mutate { $0.lastSyncedAt = SyncTime.string(Date()); $0.lastError = nil }
            phase = .idle
            return outcome
        } catch let error as SyncError {
            phase = .error
            if error.requiresRepairing {
                // Credential revoked: drop back to pairing, keep every local note
                // and every unsent local intent.
                try? credentials.setToken(nil)
                try? store.resetPairing()
            }
            try? store.mutate { $0.lastError = String(describing: error) }
            throw error
        }
    }

    // MARK: - Snapshot

    /// Pages a whole snapshot into a staging buffer, then commits the mirror and
    /// cursor together. A partial snapshot is never applied as complete.
    public func takeSnapshot() async throws {
        phase = .snapshotting
        var attempts = 0

        while true {
            attempts += 1
            do {
                var staged: [SyncNode] = []
                var snapshotToken: String?
                var cursor: String?
                var pageToken: String?

                repeat {
                    let capturedToken = snapshotToken
                    let capturedPage = pageToken
                    let page = try await withRetry(policy: retry) {
                        try await self.transport.listNodes(spaceId: self.spaceId,
                                                           snapshotToken: capturedToken,
                                                           pageToken: capturedPage,
                                                           limit: self.effectivePageLimit)
                    }
                    if snapshotToken == nil {
                        snapshotToken = page.snapshotToken
                        cursor = page.snapshotCursor
                    }
                    staged.append(contentsOf: page.nodes)
                    pageToken = page.nextPageToken
                } while pageToken != nil

                // One transaction: mirror replacement and cursor together.
                try store.mutate { state in
                    var mirror: [String: MirrorEntry] = [:]
                    for node in staged {
                        let existingBase = state.mirror[node.id]?.mergeBaseBlobId
                        mirror[node.id] = MirrorEntry(node: node, mergeBaseBlobId: existingBase)
                    }
                    state.mirror = mirror
                    state.lastCommittedCursor = cursor
                }

                if let cursor {
                    try? await transport.acknowledgeCursor(spaceId: spaceId, cursor: cursor)
                }
                return

            } catch SyncError.gone {
                // Snapshot expired mid-paging: discard staged work, start over.
                guard attempts < 3 else {
                    throw SyncError.gone(detail: "snapshot kept expiring")
                }
                continue
            }
        }
    }

    // MARK: - Pull

    private struct PullResult {
        var updated: [RemoteDocument] = []
        var removed: [RemoteTombstone] = []
    }

    private func pullChanges() async throws -> PullResult {
        phase = .pulling
        var result = PullResult()
        var guardCounter = 0

        while true {
            guardCounter += 1
            guard guardCounter < 1000 else { break }

            let cursor = store.state.lastCommittedCursor
            let page: ChangePage
            do {
                page = try await withRetry(policy: retry) {
                    try await self.transport.changes(spaceId: self.spaceId,
                                                     cursor: cursor, limit: self.effectivePageLimit)
                }
            } catch SyncError.gone {
                // History no longer covers our cursor: resnapshot, safely.
                try await takeSnapshot()
                let refreshed = try await materialiseWholeMirror()
                result.updated.append(contentsOf: refreshed)
                return result
            }

            // Fetch content before committing, so a failed download doesn't
            // advance the cursor past changes we haven't applied.
            var documents: [RemoteDocument] = []
            var tombstones: [RemoteTombstone] = []
            for change in page.changes {
                switch change.operation {
                case .delete:
                    let known = store.state.entry(forNode: change.nodeId)
                    tombstones.append(RemoteTombstone(
                        nodeId: change.nodeId,
                        name: change.node?.name ?? known?.name ?? "",
                        folder: folderName(of: change.node?.parentId ?? known?.parentId)))
                case .upsert:
                    guard let node = change.node else { continue }
                    if node.isTombstone {
                        tombstones.append(RemoteTombstone(
                            nodeId: node.id, name: node.name,
                            folder: folderName(of: node.parentId)))
                    } else if node.kind == .file, let document = try await materialise(node) {
                        documents.append(document)
                    }
                }
            }

            // Apply the complete page and its cursor in one transaction.
            let nextCursor = page.nextCursor
            try store.mutate { state in
                for change in page.changes {
                    switch change.operation {
                    case .upsert:
                        if let node = change.node { state.applyToMirror(node) }
                    case .delete:
                        if var entry = state.mirror[change.nodeId] {
                            entry.isTombstone = true
                            if let node = change.node { entry.version = node.version }
                            state.mirror[change.nodeId] = entry
                        }
                    }
                }
                // Replay-safe: re-applying the same page is idempotent.
                if let nextCursor { state.lastCommittedCursor = nextCursor }
            }

            if let nextCursor {
                try? await transport.acknowledgeCursor(spaceId: spaceId, cursor: nextCursor)
            }

            result.updated.append(contentsOf: documents)
            result.removed.append(contentsOf: tombstones)

            if !page.hasMore { break }
        }
        return result
    }

    /// Downloads and verifies a node's blob, pairing it with the merge base.
    private func materialise(_ node: SyncNode) async throws -> RemoteDocument? {
        guard let blob = node.blob else { return nil }

        let content: Data
        if let cached = blobs.data(for: blob.id) {
            content = cached
        } else {
            let downloaded = try await withRetry(policy: retry) {
                try await self.transport.downloadBlob(spaceId: self.spaceId,
                                                      blobID: blob.id, offset: 0)
            }
            // Throws rather than exposing unverified bytes.
            try blobs.store(downloaded, expecting: blob.id,
                            expectedSize: blob.size > 0 ? blob.size : nil)
            content = downloaded
        }

        let baseBlobId = store.state.entry(forNode: node.id)?.mergeBaseBlobId
        return RemoteDocument(nodeId: node.id,
                              name: node.name,
                              folder: folderName(of: node.parentId),
                              mediaType: node.mediaType,
                              appProperties: node.appProperties,
                              content: content,
                              version: node.version,
                              base: baseBlobId.flatMap { blobs.data(for: $0) })
    }

    /// After a forced resnapshot, hand the app every file we hold so it can
    /// reconcile from scratch.
    private func materialiseWholeMirror() async throws -> [RemoteDocument] {
        var documents: [RemoteDocument] = []
        for entry in store.state.mirror.values
        where entry.kind == .file && !entry.isTombstone && entry.blobId != nil {
            let node = SyncNode(id: entry.nodeId, kind: .file, parentId: entry.parentId,
                                name: entry.name, mediaType: entry.mediaType,
                                blob: entry.blobId.map { BlobRef(id: $0, size: 0,
                                                                 sha256: Digest.bareHex($0)) },
                                appProperties: entry.appProperties, version: entry.version)
            if let document = try await materialise(node) { documents.append(document) }
        }
        return documents
    }

    /// Marks a record as reconciled, so the next merge has the right base.
    public func recordMergeBase(nodeId: String, content: Data) throws {
        let ref = try blobs.storeLocal(content)
        try store.mutate { state in
            guard var entry = state.mirror[nodeId] else { return }
            entry.mergeBaseBlobId = ref.id
            state.mirror[nodeId] = entry
        }
    }

    // MARK: - Push

    /// Ensures `notes/` and `drawings/` exist before any file references them.
    private func ensureFolders() async throws {
        let root = try requireRoot()
        var needed: [String] = []
        for folder in [SyncEngine.notesFolder, SyncEngine.drawingsFolder]
        where store.state.child(of: root, named: folder) == nil {
            let alreadyQueued = store.state.outbox.contains {
                $0.kind == .putFolder && $0.name == folder
            }
            if !alreadyQueued { needed.append(folder) }
        }
        guard !needed.isEmpty else { return }

        try store.mutate { state in
            for folder in needed {
                state.enqueue(OutboxItem(kind: .putFolder,
                                         recordKey: "folder:\(folder)",
                                         folder: folder,
                                         nodeId: UUIDv7.string(),
                                         parentId: root,
                                         name: folder))
            }
        }
        _ = try await pushOutbox()
    }

    /// Re-points queued work at the tree as it actually is right now.
    ///
    /// An item is queued the instant you type, but by the time it's pushed the
    /// mirror may have learned things: that the folder it targets already
    /// exists under a different node id (another device, or a previous install,
    /// created it), or that its file already exists at some version. Trusting
    /// the ids captured at enqueue time produces `parent_not_found` rejections
    /// and phantom conflicts that never drain. So parent, node id and
    /// baseVersion are all resolved here, immediately before the push.
    private func resolveOutboxAgainstMirror() throws {
        guard let root = store.state.rootNodeId else { return }

        try store.mutate { state in
            var resolved: [OutboxItem] = []

            for var item in state.outbox {
                // A genuine content conflict is the user's to settle; leave it.
                if item.status == .blocked && !item.isRetryableRejection {
                    resolved.append(item)
                    continue
                }

                let folderName = item.folder ?? Self.inferFolder(from: item.recordKey)
                let before = item

                switch item.kind {
                case .putFolder:
                    // Someone already made it — the intent is satisfied.
                    if state.child(of: root, named: item.name) != nil { continue }

                case .putFile:
                    guard let folderName,
                          let folderNode = state.child(of: root, named: folderName) else {
                        break   // folder still unknown; the queued creation covers it
                    }
                    item.parentId = folderNode.nodeId
                    if let existing = state.child(of: folderNode.nodeId, named: item.name) {
                        // Update the node that's really there, at its real version.
                        item.nodeId = existing.nodeId
                        item.baseVersion = existing.version
                    } else {
                        item.baseVersion = nil   // a create, not an update
                    }

                case .delete:
                    guard let folderName,
                          let folderNode = state.child(of: root, named: folderName),
                          let existing = state.child(of: folderNode.nodeId, named: item.name) else {
                        continue   // already gone server-side; nothing to do
                    }
                    item.nodeId = existing.nodeId
                    item.baseVersion = existing.version
                }

                if item != before {
                    // A changed body is a *different* logical mutation. Keeping
                    // the old `clientMutationId` earns an `idempotency_mismatch`
                    // — the server remembers the id against its first content —
                    // so this needs a fresh id as well as a fresh batch key.
                    item.id = UUIDv7.string()
                    item.status = .pending
                    item.batchKey = nil
                    item.lastProblem = nil
                    item.uploadLocation = nil
                    item.committedOffset = nil
                    item.attempts = 0
                } else if item.isRetryableRejection {
                    // Nothing to re-point. Give it a bounded number of genuine
                    // fresh attempts rather than either looping forever or
                    // stranding it silently.
                    let attempts = (item.attempts ?? 0) + 1
                    guard attempts <= 3 else {
                        resolved.append(item)
                        continue
                    }
                    item.id = UUIDv7.string()
                    item.attempts = attempts
                    item.status = .pending
                    item.batchKey = nil
                    item.lastProblem = nil
                }
                resolved.append(item)
            }

            state.outbox = resolved

            // Drop conflict records for work that no longer exists, and for
            // folders — a folder name clash is not a content conflict.
            state.conflicts.removeAll { record in
                guard !record.resolved else { return false }
                if record.recordKey.hasPrefix("folder:") { return true }
                return !state.outbox.contains { $0.recordKey == record.recordKey }
            }
        }
    }

    /// Fallback for items queued before `folder` was recorded on them.
    private static func inferFolder(from recordKey: String) -> String? {
        if recordKey.hasPrefix("note:") { return notesFolder }
        if recordKey.hasPrefix("drawing:") { return drawingsFolder }
        if recordKey.hasPrefix("folder:") { return nil }
        return nil
    }

    /// Uploads any blobs the outbox needs, then submits mutations in batches.
    @discardableResult
    public func pushOutbox() async throws -> Int {
        phase = .pushing
        var pushed = 0
        try resolveOutboxAgainstMirror()

        while true {
            // Folders first: a file mutation is pointless if its parent is unborn.
            let ready = store.state.outbox
                .filter { $0.status != .blocked }
                .sorted { lhs, rhs in
                    if (lhs.kind == .putFolder) != (rhs.kind == .putFolder) {
                        return lhs.kind == .putFolder
                    }
                    return lhs.id < rhs.id
                }
            guard !ready.isEmpty else { break }

            let batch = Array(ready.prefix(effectiveBatchSize))
            for item in batch where item.kind == .putFile {
                try await uploadBlob(for: item)
            }

            // One stable idempotency key per batch body. Reused verbatim on
            // retry; a changed membership gets a new key.
            let batchKey = batch.first?.batchKey ?? UUIDv7.string()
            let ids = batch.map(\.id)
            try store.mutate { state in
                for id in ids {
                    state.updateOutboxItem(id: id) { item in
                        item.status = .inFlight
                        item.batchKey = batchKey
                    }
                }
            }

            let mutations = batch.map { $0.mutation() }
            let response: MutationResponse
            do {
                response = try await withRetry(policy: retry) {
                    try await self.transport.submit(spaceId: self.spaceId,
                                                    mutations: mutations,
                                                    atomic: false,
                                                    idempotencyKey: batchKey)
                }
            } catch {
                // Leave the batch in flight with its key so the identical body
                // can be retried later.
                throw error
            }

            let applied = try apply(results: response.results, batch: batch)
            pushed += applied

            // Nothing progressed — stop rather than spin.
            if applied == 0 && response.results.allSatisfy({
                $0.status == .conflict || $0.status == .rejected
            }) { break }
            if batch.count == ready.count && applied == batch.count { break }
            if applied == 0 { break }
        }
        return pushed
    }

    private func apply(results: [MutationResult], batch: [OutboxItem]) throws -> Int {
        var applied = 0
        let byId = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })

        try store.mutate { state in
            for result in results {
                guard let item = byId[result.clientMutationId] else { continue }
                switch result.status {
                case .applied, .duplicate:
                    // `duplicate` means a retry landed on work already done.
                    if let node = result.node {
                        var entry = MirrorEntry(node: node)
                        entry.mergeBaseBlobId = item.content.map { BlobRef(data: $0).id }
                            ?? state.mirror[node.id]?.mergeBaseBlobId
                        state.mirror[node.id] = entry
                    }
                    state.removeOutboxItem(id: item.id)
                    applied += 1

                case .conflict:
                    if let current = result.currentNode, item.kind == .putFolder {
                        // The folder is simply already there; adopt it and move on.
                        state.applyToMirror(current)
                        state.removeOutboxItem(id: item.id)
                        applied += 1
                        continue
                    }
                    // Keep local intent; record the server's version; never
                    // overwrite it silently.
                    if let current = result.currentNode {
                        state.applyToMirror(current)
                        let alreadyOpen = state.conflicts.contains {
                            $0.recordKey == item.recordKey && !$0.resolved
                        }
                        if !alreadyOpen {
                            state.conflicts.append(ConflictRecord(
                                recordKey: item.recordKey,
                                nodeId: item.nodeId,
                                localContent: item.content,
                                serverVersion: current.version,
                                serverBlobId: current.blob?.id))
                        }
                    }
                    state.updateOutboxItem(id: item.id) {
                        $0.status = .blocked
                        $0.lastProblem = OutboxItem.conflictProblem
                    }

                case .rejected:
                    // Keep enough to explain or repair; do not loop on it.
                    state.updateOutboxItem(id: item.id) {
                        $0.status = .blocked
                        $0.lastProblem = result.problem.map {
                            String(data: CanonicalJSON.encode($0), encoding: .utf8) ?? "rejected"
                        } ?? "rejected"
                    }
                }
            }
        }
        return applied
    }

    /// tus upload with resume. Skips entirely when the server already has the blob.
    private func uploadBlob(for item: OutboxItem) async throws {
        guard let content = item.content else { return }
        let ref = BlobRef(data: content)

        if try await withRetry(policy: retry, operation: {
            try await self.transport.blobExists(spaceId: self.spaceId, blobID: ref.id)
        }) { return }

        // Resume an interrupted upload when we still hold its location.
        let uploadLocation: String
        var offset: Int

        if let existing = item.uploadLocation {
            uploadLocation = existing
            // Trust the server's offset, never our own bookkeeping.
            offset = try await serverOffset(at: existing)
        } else {
            let session = try await withRetry(policy: retry) {
                try await self.transport.createUpload(spaceId: self.spaceId,
                                                      length: ref.size,
                                                      sha256Hex: ref.sha256)
            }
            uploadLocation = session.location
            offset = session.offset
            try store.mutate { state in
                state.updateOutboxItem(id: item.id) {
                    $0.uploadLocation = session.location
                    $0.uploadExpiresAt = session.expiresAt
                    $0.committedOffset = session.offset
                }
            }
        }

        while offset < content.count {
            let end = min(offset + settings.uploadChunkSize, content.count)
            let chunk = content.subdata(in: offset..<end)
            let sendOffset = offset
            do {
                offset = try await withRetry(policy: retry) {
                    try await self.transport.appendChunk(location: uploadLocation,
                                                         offset: sendOffset, data: chunk)
                }
            } catch SyncError.offsetConflict(let reported) {
                // Our idea of the offset was stale — re-read and continue.
                if let reported {
                    offset = reported
                } else {
                    offset = try await serverOffset(at: uploadLocation)
                }
                continue
            } catch SyncError.checksumMismatch(let reported) {
                // Retransmit from wherever the server actually is.
                if let reported {
                    offset = reported
                } else {
                    offset = try await serverOffset(at: uploadLocation)
                }
                continue
            }
            let committed = offset
            try store.mutate { state in
                state.updateOutboxItem(id: item.id) { $0.committedOffset = committed }
            }
        }

        // Confirm the blob exists before any node references it.
        let present = try await withRetry(policy: retry) {
            try await self.transport.blobExists(spaceId: self.spaceId, blobID: ref.id)
        }
        guard present else {
            throw SyncError.malformedResponse("upload finished but blob \(ref.id) is absent")
        }
        try blobs.store(content, expecting: ref.id)
    }

    // MARK: - App-facing intent

    /// Records a create/update. Durable before any network work begins.
    public func enqueueUpsert(recordKey: String, folder: String, fileName: String,
                              mediaType: String, appProperties: [String: JSONValue],
                              content: Data) throws {
        let root = try requireRoot()
        let state = store.state
        let folderNodeId = state.child(of: root, named: folder)?.nodeId
        // If the folder isn't on the server yet, adopt the node ID the queued
        // folder mutation will create, so the file can reference it.
        let pendingFolder = state.outbox.first { $0.kind == .putFolder && $0.name == folder }
        let parentId = folderNodeId ?? pendingFolder?.nodeId ?? UUIDv7.string()

        let existing = folderNodeId.flatMap { state.child(of: $0, named: fileName) }
        let nodeId = existing?.nodeId
            ?? state.outbox.first { $0.recordKey == recordKey }?.nodeId
            ?? UUIDv7.string()

        var item = OutboxItem(kind: .putFile, recordKey: recordKey, folder: folder,
                              nodeId: nodeId, parentId: parentId, name: fileName,
                              mediaType: mediaType, appProperties: appProperties,
                              content: content, baseVersion: existing?.version)
        item.clientModifiedAt = SyncTime.string(Date())

        if folderNodeId == nil && pendingFolder == nil {
            // Folder isn't known at all yet — queue it in the same transaction.
            try store.mutate { state in
                state.enqueue(OutboxItem(kind: .putFolder, recordKey: "folder:\(folder)",
                                         folder: folder, nodeId: parentId,
                                         parentId: root, name: folder))
                state.enqueue(item)
            }
        } else {
            try store.mutate { $0.enqueue(item) }
        }
    }

    /// Records a deletion, carrying the last applied version so a racing remote
    /// edit surfaces as a conflict instead of being silently destroyed.
    public func enqueueDelete(recordKey: String, folder: String, fileName: String) throws {
        let root = try requireRoot()
        let state = store.state
        guard let folderNodeId = state.child(of: root, named: folder)?.nodeId,
              let existing = state.child(of: folderNodeId, named: fileName) else {
            // Never synced; just drop any pending intent for it.
            try store.mutate { state in
                state.outbox.removeAll { $0.recordKey == recordKey && $0.status == .pending }
            }
            return
        }
        let item = OutboxItem(kind: .delete, recordKey: recordKey, folder: folder,
                              nodeId: existing.nodeId, parentId: folderNodeId,
                              name: fileName, baseVersion: existing.version)
        try store.mutate { $0.enqueue(item) }
    }

    /// Submits an app-merged version against the server's current version, which
    /// is how a conflict actually clears.
    public func resolveConflict(_ conflictId: String, mergedContent: Data?) throws {
        try store.mutate { state in
            guard let index = state.conflicts.firstIndex(where: { $0.id == conflictId }) else { return }
            let conflict = state.conflicts[index]
            state.conflicts[index].resolved = true

            // Retire the blocked item; a merged version goes back as fresh intent.
            state.outbox.removeAll { $0.recordKey == conflict.recordKey && $0.status == .blocked }

            if let mergedContent, let entry = state.mirror[conflict.nodeId] {
                var item = OutboxItem(kind: .putFile, recordKey: conflict.recordKey,
                                      folder: Self.inferFolder(from: conflict.recordKey),
                                      nodeId: conflict.nodeId, parentId: entry.parentId,
                                      name: entry.name, mediaType: entry.mediaType,
                                      appProperties: entry.appProperties,
                                      content: mergedContent,
                                      baseVersion: conflict.serverVersion)
                item.status = .pending
                state.enqueue(item)
            }
        }
    }

    public func clearResolvedConflicts() throws {
        try store.mutate { $0.conflicts.removeAll { $0.resolved } }
    }

    // MARK: - Helpers

    private var spaceId: String { store.state.spaceId ?? "" }

    private func serverOffset(at location: String) async throws -> Int {
        try await withRetry(policy: retry) {
            try await self.transport.uploadOffset(location: location)
        }
    }

    private func requireRoot() throws -> String {
        guard let root = store.state.rootNodeId else { throw SyncError.notPaired }
        return root
    }

    private func folderName(of parentId: String?) -> String {
        guard let parentId, let entry = store.state.mirror[parentId] else { return "" }
        return entry.name
    }
}
