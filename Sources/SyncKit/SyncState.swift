import Foundation

// MARK: - Mirror

/// What the server last told us about a node. Deliberately small — the bytes
/// live in the blob cache, not here.
public struct MirrorEntry: Codable, Equatable, Sendable {
    public var nodeId: String
    public var version: Int
    public var parentId: String?
    public var name: String
    public var kind: NodeKind
    public var blobId: String?
    public var mediaType: String?
    public var appProperties: [String: JSONValue]
    public var isTombstone: Bool
    /// Blob this client last reconciled into local app content — the common
    /// base for three-way merges.
    public var mergeBaseBlobId: String?

    public init(node: SyncNode, mergeBaseBlobId: String? = nil) {
        self.nodeId = node.id
        self.version = node.version
        self.parentId = node.parentId
        self.name = node.name
        self.kind = node.kind
        self.blobId = node.blob?.id
        self.mediaType = node.mediaType
        self.appProperties = node.appProperties
        self.isTombstone = node.isTombstone
        self.mergeBaseBlobId = mergeBaseBlobId
    }
}

// MARK: - Outbox

public enum OutboxKind: String, Codable, Sendable {
    case putFolder, putFile, delete
}

public enum OutboxStatus: String, Codable, Sendable {
    case pending        // free to coalesce further edits into
    case inFlight       // body is frozen under an idempotency key
    case blocked        // conflicted or rejected; needs resolution, never loops
}

public extension OutboxItem {
    /// Marks a genuine content clash, which only the app/user can settle.
    static let conflictProblem = "conflict"

    /// A rejection is the server saying the *request* was wrong — a stale parent
    /// or version. Those are worth re-resolving and retrying; a content
    /// conflict is not.
    var isRetryableRejection: Bool {
        status == .blocked && lastProblem != OutboxItem.conflictProblem
    }
}

/// One durable local intent. Everything needed to replay it after a crash is
/// here — including the tus upload location and committed offset.
public struct OutboxItem: Codable, Equatable, Sendable {
    public var id: String                    // UUIDv7, also the clientMutationId
    public var kind: OutboxKind
    public var status: OutboxStatus
    /// App-level key, e.g. `note:<uuid>` — what coalescing groups on.
    public var recordKey: String
    /// Which folder this record lives in. Optional so state files written
    /// before this field existed still decode.
    public var folder: String?
    public var nodeId: String
    public var parentId: String?
    public var name: String
    public var mediaType: String?
    public var appProperties: [String: JSONValue]
    /// Content for file puts. Held inline: notes are small and this keeps the
    /// intent durable without a second store to keep consistent.
    public var content: Data?
    public var baseVersion: Int?
    public var clientModifiedAt: String
    /// Batch idempotency key, assigned when the item first goes in flight.
    public var batchKey: String?
    // Resumable upload progress
    public var uploadLocation: String?
    public var uploadExpiresAt: String?
    public var committedOffset: Int?
    public var lastProblem: String?
    /// Bounded retry counter for rejections that re-resolution can't explain.
    /// Optional so older state files still decode.
    public var attempts: Int?

    public var expectedBlob: BlobRef? {
        guard let content else { return nil }
        return BlobRef(data: content)
    }

    public init(id: String = UUIDv7.string(), kind: OutboxKind, status: OutboxStatus = .pending,
                recordKey: String, folder: String? = nil, nodeId: String,
                parentId: String?, name: String,
                mediaType: String? = nil, appProperties: [String: JSONValue] = [:],
                content: Data? = nil, baseVersion: Int? = nil,
                clientModifiedAt: String = SyncTime.string(Date())) {
        self.id = id
        self.kind = kind
        self.status = status
        self.recordKey = recordKey
        self.folder = folder
        self.nodeId = nodeId
        self.parentId = parentId
        self.name = name
        self.mediaType = mediaType
        self.appProperties = appProperties
        self.content = content
        self.baseVersion = baseVersion
        self.clientModifiedAt = clientModifiedAt
    }

    public func mutation() -> Mutation {
        switch kind {
        case .delete:
            return .delete(clientMutationId: id, nodeId: nodeId,
                           baseVersion: baseVersion, recursive: false)
        case .putFolder:
            let node = SyncNode(id: nodeId, kind: .folder, parentId: parentId, name: name,
                                mediaType: nil, blob: nil, appProperties: appProperties,
                                clientModifiedAt: clientModifiedAt)
            return .put(clientMutationId: id, node: node, baseVersion: baseVersion)
        case .putFile:
            let node = SyncNode(id: nodeId, kind: .file, parentId: parentId, name: name,
                                mediaType: mediaType, blob: expectedBlob,
                                appProperties: appProperties,
                                clientModifiedAt: clientModifiedAt)
            return .put(clientMutationId: id, node: node, baseVersion: baseVersion)
        }
    }
}

// MARK: - Conflicts

public struct ConflictRecord: Codable, Equatable, Sendable {
    public var id: String
    public var recordKey: String
    public var nodeId: String
    /// The local content we tried to push, kept verbatim.
    public var localContent: Data?
    /// The server's current node at the moment of the clash.
    public var serverVersion: Int
    public var serverBlobId: String?
    public var detectedAt: String
    /// Set once the app has materialised both sides for the user.
    public var resolved: Bool

    public init(recordKey: String, nodeId: String, localContent: Data?,
                serverVersion: Int, serverBlobId: String?) {
        self.id = UUIDv7.string()
        self.recordKey = recordKey
        self.nodeId = nodeId
        self.localContent = localContent
        self.serverVersion = serverVersion
        self.serverBlobId = serverBlobId
        self.detectedAt = SyncTime.string(Date())
        self.resolved = false
    }
}

// MARK: - State

/// Everything the client must persist, in one value so it can be committed in a
/// single atomic write. The handoff repeatedly requires "one local transaction";
/// for a library this size, an atomic file replace *is* that transaction, and it
/// is far easier to reason about than a hand-rolled SQLite schema.
public struct SyncState: Codable, Equatable, Sendable {
    public var installationId: String
    public var spaceId: String?
    public var rootNodeId: String?
    public var deviceId: String?
    public var deviceName: String?
    public var lastCommittedCursor: String?
    public var mirror: [String: MirrorEntry]        // nodeId → entry
    public var outbox: [OutboxItem]
    public var conflicts: [ConflictRecord]
    public var lastSyncedAt: String?
    public var lastError: String?

    public init(installationId: String = UUIDv7.string()) {
        self.installationId = installationId
        self.mirror = [:]
        self.outbox = []
        self.conflicts = []
    }

    public var isPaired: Bool { spaceId != nil && rootNodeId != nil }

    // MARK: Tree lookups

    public func child(of parentId: String, named name: String) -> MirrorEntry? {
        // Portable name matching: the server treats names case-insensitively.
        mirror.values.first {
            $0.parentId == parentId && !$0.isTombstone
                && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    public func children(of parentId: String) -> [MirrorEntry] {
        mirror.values.filter { $0.parentId == parentId && !$0.isTombstone }
    }

    public func entry(forNode nodeId: String) -> MirrorEntry? { mirror[nodeId] }

    // MARK: Outbox helpers

    public func pendingItem(forRecord recordKey: String) -> OutboxItem? {
        outbox.first { $0.recordKey == recordKey && $0.status == .pending }
    }

    public mutating func enqueue(_ item: OutboxItem) {
        // Coalesce into an existing pending item; never rewrite one in flight,
        // because its body is frozen under an idempotency key.
        if let index = outbox.firstIndex(where: {
            $0.recordKey == item.recordKey && $0.status == .pending
        }) {
            var existing = outbox[index]
            existing.kind = item.kind
            existing.content = item.content
            existing.name = item.name
            existing.parentId = item.parentId
            existing.mediaType = item.mediaType
            existing.appProperties = item.appProperties
            existing.clientModifiedAt = item.clientModifiedAt
            // A newer base version may have landed since this item was queued.
            existing.baseVersion = item.baseVersion ?? existing.baseVersion
            // Content changed, so any half-finished upload no longer applies.
            existing.uploadLocation = nil
            existing.committedOffset = nil
            existing.uploadExpiresAt = nil
            outbox[index] = existing
        } else {
            outbox.append(item)
        }
    }

    public mutating func removeOutboxItem(id: String) {
        outbox.removeAll { $0.id == id }
    }

    public mutating func updateOutboxItem(id: String, _ mutate: (inout OutboxItem) -> Void) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        mutate(&outbox[index])
    }

    public mutating func applyToMirror(_ node: SyncNode) {
        let existingBase = mirror[node.id]?.mergeBaseBlobId
        mirror[node.id] = MirrorEntry(node: node, mergeBaseBlobId: existingBase)
    }
}

// MARK: - Persistence

/// Atomic, crash-safe persistence for `SyncState`.
///
/// `mutate` serialises callers, applies the change to an in-memory copy, and
/// only publishes it after the bytes are durably on disk — so an interrupted
/// write leaves the previous consistent state, never a half-applied one.
public final class SyncStateStore: @unchecked Sendable {

    private let url: URL
    private var cached: SyncState
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("state.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SyncState.self, from: data) {
            self.cached = decoded
        } else {
            self.cached = SyncState()
            try? write(cached)
        }
    }

    public var state: SyncState {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Applies `body` and commits the result in one transaction. If the write
    /// throws, the in-memory state is left untouched.
    @discardableResult
    public func mutate<T>(_ body: (inout SyncState) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var working = cached
        let result = try body(&working)
        guard working != cached else { return result }
        try write(working)
        cached = working
        return result
    }

    /// Drops paired identity and server-derived state, keeping the installation
    /// ID and any unsent local intent. Used when a token is revoked.
    public func resetPairing() throws {
        try mutate { state in
            state.spaceId = nil
            state.rootNodeId = nil
            state.deviceId = nil
            state.lastCommittedCursor = nil
            state.mirror = [:]
            for index in state.outbox.indices {
                state.outbox[index].status = .pending
                state.outbox[index].batchKey = nil
                state.outbox[index].uploadLocation = nil
                state.outbox[index].committedOffset = nil
                state.outbox[index].baseVersion = nil
            }
        }
    }

    private func write(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".state-\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        // Replace in one step so a crash can never expose a partial state file.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
