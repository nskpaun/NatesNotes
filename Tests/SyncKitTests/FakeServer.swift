import Foundation
@testable import SyncKit

/// In-process implementation of the documented server semantics.
///
/// It is deliberately strict where the handoff is strict — version checks,
/// idempotency, snapshot/cursor expiry, tus offsets — so the tests exercise the
/// client's real behaviour rather than a forgiving stub.
final class FakeServer: SyncTransport, @unchecked Sendable {

    struct StoredNode {
        var node: SyncNode
    }

    let spaceId = "space-0001"
    let rootNodeId = "root-0001"
    let slug: String
    let validCode: String

    private let lock = NSLock()

    private(set) var nodes: [String: SyncNode] = [:]
    private(set) var blobs: [String: Data] = [:]
    /// Append-only log; each entry's index + 1 is its cursor.
    private(set) var changeLog: [NodeChange] = []
    private var uploads: [String: (expectedLength: Int, digest: String, data: Data)] = [:]
    private var idempotency: [String: MutationResponse] = [:]
    private var snapshots: [String: [String]] = [:]      // token → ordered node ids
    private var codeUsed = false

    // Test knobs
    var pageSize = 200
    var expireSnapshotAfterFirstPage = false
    var expireCursors = false
    /// Cursors at or below this are considered trimmed from history.
    var minimumValidCursor = 0
    var failNextRequests = 0
    var failureStatus = 503
    var tokenRevoked = false
    var corruptDownloads = false
    /// Accept only this many bytes per PATCH, to force resumes.
    var maxChunkAccepted: Int?
    var rejectNextChecksum = false

    // Observability
    private(set) var mutationCalls = 0
    private(set) var uploadPatchCalls = 0
    private(set) var listNodeCalls = 0
    private(set) var acknowledgedCursors: [String] = []
    private(set) var requestAttempts = 0

    init(slug: String = "natesnotes", code: String = "PAIR-CODE") {
        self.slug = slug
        self.validCode = code
        let root = SyncNode(id: rootNodeId, kind: .folder, parentId: nil, name: "",
                            version: 1, spaceId: spaceId,
                            createdAt: SyncTime.string(Date()))
        nodes[rootNodeId] = root
    }

    // MARK: - Helpers

    private func checkAuth() throws {
        requestAttempts += 1
        if tokenRevoked { throw SyncError.unauthorized }
        if failNextRequests > 0 {
            failNextRequests -= 1
            throw SyncError.from(status: failureStatus, retryAfter: nil, body: "injected")
        }
    }

    private func log(_ operation: ChangeOperation, _ node: SyncNode) {
        changeLog.append(NodeChange(cursor: String(changeLog.count + 1),
                                    operation: operation, nodeId: node.id, node: node))
    }

    /// Seeds content directly, as if another device had pushed it.
    @discardableResult
    func seedFile(name: String, parentId: String, content: Data,
                  mediaType: String = "application/json",
                  appProperties: [String: JSONValue] = [:],
                  nodeId: String = UUIDv7.string()) -> SyncNode {
        lock.lock(); defer { lock.unlock() }
        let ref = BlobRef(data: content)
        blobs[ref.id] = content
        let existing = nodes.values.first { $0.parentId == parentId && $0.name == name }
        var node = SyncNode(id: existing?.id ?? nodeId, kind: .file, parentId: parentId,
                            name: name, mediaType: mediaType, blob: ref,
                            appProperties: appProperties,
                            version: (existing?.version ?? 0) + 1, spaceId: spaceId)
        node.updatedAt = SyncTime.string(Date())
        nodes[node.id] = node
        log(.upsert, node)
        return node
    }

    @discardableResult
    func seedFolder(name: String, parentId: String,
                    nodeId: String = UUIDv7.string()) -> SyncNode {
        lock.lock(); defer { lock.unlock() }
        let node = SyncNode(id: nodeId, kind: .folder, parentId: parentId, name: name,
                            version: 1, spaceId: spaceId)
        nodes[node.id] = node
        log(.upsert, node)
        return node
    }

    func node(named name: String, in parentId: String) -> SyncNode? {
        lock.lock(); defer { lock.unlock() }
        return nodes.values.first {
            $0.parentId == parentId && $0.name == name && !$0.isTombstone
        }
    }

    var fileCount: Int {
        lock.lock(); defer { lock.unlock() }
        return nodes.values.filter { $0.kind == .file && !$0.isTombstone }.count
    }

    // MARK: - Capabilities

    var capabilityLimits = ServerCapabilities(maxPageSize: 500, maxMutationBatch: 100,
                                              features: ["snapshots", "changes", "events",
                                                         "range-download", "resumable-upload",
                                                         "atomic-batch"])

    func capabilities() async throws -> ServerCapabilities { capabilityLimits }

    // MARK: - Pairing

    func redeemPairing(_ request: PairingRequest) async throws -> PairingResult {
        lock.lock(); defer { lock.unlock() }
        requestAttempts += 1
        guard request.code == validCode, !codeUsed else {
            throw SyncError.forbidden(detail: "invalid or already-used code")
        }
        codeUsed = true
        return PairingResult(
            token: "secret-token-\(UUID().uuidString)",
            tokenType: "Bearer",
            device: SyncDevice(id: "device-1", installationId: request.deviceId,
                               name: request.deviceName, platform: request.platform,
                               appId: request.appId, scopes: ["space:read", "space:write"],
                               createdAt: SyncTime.string(Date()), lastSeenAt: nil),
            spaces: [SyncSpace(id: spaceId, slug: slug, displayName: "Nate's Notes",
                               rootNodeId: rootNodeId, quotaBytes: 1 << 30, usedBytes: 0,
                               capabilities: ["read", "write", "events", "resumable-upload"])])
    }

    func currentDevice() async throws -> SyncDevice {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        return SyncDevice(id: "device-1", installationId: nil, name: "Test",
                          platform: "macOS", appId: nil, scopes: nil,
                          createdAt: nil, lastSeenAt: nil)
    }

    func revokeCurrentDevice() async throws {
        lock.lock(); defer { lock.unlock() }
        tokenRevoked = true
    }

    func spaces() async throws -> [SyncSpace] {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        return [SyncSpace(id: spaceId, slug: slug, displayName: "Nate's Notes",
                          rootNodeId: rootNodeId)]
    }

    // MARK: - Snapshot

    func listNodes(spaceId: String, snapshotToken: String?, pageToken: String?,
                   limit: Int) async throws -> NodePage {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        listNodeCalls += 1

        let token: String
        let ordered: [String]
        if let snapshotToken {
            guard let existing = snapshots[snapshotToken] else {
                throw SyncError.gone(detail: "snapshot expired")
            }
            token = snapshotToken
            ordered = existing
        } else {
            token = "snap-\(snapshots.count + 1)"
            ordered = nodes.keys.sorted()
            snapshots[token] = ordered
        }

        let offset = pageToken.flatMap(Int.init) ?? 0
        let size = min(pageSize, limit)
        let slice = Array(ordered.dropFirst(offset).prefix(size))
        let next = offset + slice.count < ordered.count ? String(offset + slice.count) : nil

        // Simulates a snapshot expiring between pages.
        if expireSnapshotAfterFirstPage && offset > 0 {
            snapshots[token] = nil
            expireSnapshotAfterFirstPage = false
            throw SyncError.gone(detail: "snapshot expired mid-page")
        }

        return NodePage(snapshotToken: token,
                        snapshotCursor: String(changeLog.count),
                        nodes: slice.compactMap { nodes[$0] },
                        nextPageToken: next)
    }

    // MARK: - Changes

    func changes(spaceId: String, cursor: String?, limit: Int) async throws -> ChangePage {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()

        let from = cursor.flatMap(Int.init) ?? 0
        if expireCursors || from < minimumValidCursor {
            throw SyncError.gone(detail: "cursor no longer in history")
        }
        guard from <= changeLog.count else {
            throw SyncError.gone(detail: "cursor beyond history")
        }

        let slice = Array(changeLog.dropFirst(from).prefix(min(pageSize, limit)))
        let next = from + slice.count
        return ChangePage(changes: slice, nextCursor: String(next),
                          hasMore: next < changeLog.count)
    }

    func acknowledgeCursor(spaceId: String, cursor: String) async throws {
        lock.lock(); defer { lock.unlock() }
        acknowledgedCursors.append(cursor)
    }

    // MARK: - Blobs

    func blobExists(spaceId: String, blobID: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        return blobs[blobID] != nil
    }

    func downloadBlob(spaceId: String, blobID: String, offset: Int) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        guard let data = blobs[blobID] else {
            throw SyncError.permanent(status: 404, detail: "no such blob")
        }
        if corruptDownloads { return Data("corrupted".utf8) }
        return offset > 0 ? data.subdata(in: offset..<data.count) : data
    }

    // MARK: - Uploads

    func createUpload(spaceId: String, length: Int, sha256Hex: String) async throws -> UploadSession {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        let id = "upload-\(uploads.count + 1)"
        uploads[id] = (length, sha256Hex, Data())
        return UploadSession(location: "/v1/spaces/\(spaceId)/uploads/\(id)",
                             offset: 0,
                             expiresAt: SyncTime.string(Date().addingTimeInterval(3600)))
    }

    private func uploadKey(_ location: String) -> String {
        String(location.split(separator: "/").last ?? "")
    }

    func uploadOffset(location: String) async throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        guard let upload = uploads[uploadKey(location)] else {
            throw SyncError.permanent(status: 404, detail: "no such upload")
        }
        return upload.data.count
    }

    func appendChunk(location: String, offset: Int, data: Data) async throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        uploadPatchCalls += 1

        let key = uploadKey(location)
        guard var upload = uploads[key] else {
            throw SyncError.permanent(status: 404, detail: "no such upload")
        }
        guard offset == upload.data.count else {
            throw SyncError.offsetConflict(serverOffset: upload.data.count)
        }
        if rejectNextChecksum {
            rejectNextChecksum = false
            throw SyncError.checksumMismatch(serverOffset: upload.data.count)
        }

        // Accept only a prefix when asked to, so the client must resume.
        let accepted = maxChunkAccepted.map { data.prefix($0) } ?? data[...]
        upload.data.append(contentsOf: accepted)
        uploads[key] = upload

        if upload.data.count == upload.expectedLength {
            let hex = Digest.hex(upload.data)
            guard hex == upload.digest else {
                throw SyncError.permanent(status: 422, detail: "final digest mismatch")
            }
            blobs["sha256:" + hex] = upload.data
        }
        return upload.data.count
    }

    // MARK: - Mutations

    func submit(spaceId: String, mutations: [Mutation], atomic: Bool,
                idempotencyKey: String) async throws -> MutationResponse {
        lock.lock(); defer { lock.unlock() }
        try checkAuth()
        mutationCalls += 1

        // Replaying a key returns the original outcome and does no new work.
        if let cached = idempotency[idempotencyKey] { return cached }

        var results: [MutationResult] = []
        for mutation in mutations {
            switch mutation.operation {
            case .put:
                guard let desired = mutation.node else {
                    results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                                  status: .rejected,
                                                  problem: .string("missing node")))
                    continue
                }
                if desired.kind == .file, let blob = desired.blob, blobs[blob.id] == nil {
                    results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                                  status: .rejected,
                                                  problem: .string("blob not uploaded")))
                    continue
                }
                let existing = nodes[desired.id]
                // Version check: a stale baseVersion is a conflict, not a write.
                if let existing, !existing.isTombstone,
                   (mutation.baseVersion ?? 0) != existing.version {
                    results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                                  status: .conflict,
                                                  currentNode: existing))
                    continue
                }
                var node = desired
                node.spaceId = spaceId
                node.version = (existing?.version ?? 0) + 1
                node.updatedAt = SyncTime.string(Date())
                node.createdAt = existing?.createdAt ?? SyncTime.string(Date())
                node.deletedAt = nil
                nodes[node.id] = node
                log(.upsert, node)
                results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                              status: .applied, node: node))

            case .delete:
                guard let id = mutation.nodeId, var node = nodes[id] else {
                    results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                                  status: .applied))
                    continue
                }
                if (mutation.baseVersion ?? 0) != node.version {
                    results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                                  status: .conflict, currentNode: node))
                    continue
                }
                node.deletedAt = SyncTime.string(Date())
                node.version += 1
                nodes[id] = node
                log(.delete, node)
                results.append(MutationResult(clientMutationId: mutation.clientMutationId,
                                              status: .applied, node: node))
            }
        }

        let response = MutationResponse(results: results, nextCursor: String(changeLog.count))
        idempotency[idempotencyKey] = response
        return response
    }
}
