import Foundation
import CryptoKit

// MARK: - Digests

public enum Digest {
    /// `sha256:<64 lowercase hex>` — the protocol's blob identifier form.
    public static func blobID(for data: Data) -> String {
        "sha256:" + hex(data)
    }

    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Strips the `sha256:` scheme if present.
    public static func bareHex(_ blobID: String) -> String {
        blobID.hasPrefix("sha256:") ? String(blobID.dropFirst(7)) : blobID
    }

    public static func isValidHex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

// MARK: - Nodes

public enum NodeKind: String, Codable, Sendable {
    case file, folder
}

public struct BlobRef: Codable, Equatable, Sendable {
    public var id: String
    public var size: Int
    public var sha256: String

    public init(id: String, size: Int, sha256: String) {
        self.id = id
        self.size = size
        self.sha256 = sha256
    }

    public init(data: Data) {
        let hex = Digest.hex(data)
        self.id = "sha256:" + hex
        self.size = data.count
        self.sha256 = hex
    }
}

/// A node in a space's tree. Unknown fields ride along in `extra` so a rewrite
/// by this client doesn't strip a field a newer server or peer added.
public struct SyncNode: Equatable, Sendable {
    public var id: String
    public var spaceId: String?
    public var kind: NodeKind
    public var parentId: String?
    public var name: String
    public var mediaType: String?
    public var blob: BlobRef?
    public var appProperties: [String: JSONValue]
    public var encryption: JSONValue?
    public var version: Int
    public var createdAt: String?
    public var updatedAt: String?
    public var clientModifiedAt: String?
    public var deletedAt: String?
    public var extra: [String: JSONValue]

    public var isTombstone: Bool { deletedAt != nil }

    public init(id: String, kind: NodeKind, parentId: String?, name: String,
                mediaType: String? = nil, blob: BlobRef? = nil,
                appProperties: [String: JSONValue] = [:], encryption: JSONValue? = nil,
                version: Int = 0, spaceId: String? = nil,
                createdAt: String? = nil, updatedAt: String? = nil,
                clientModifiedAt: String? = nil, deletedAt: String? = nil,
                extra: [String: JSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.parentId = parentId
        self.name = name
        self.mediaType = mediaType
        self.blob = blob
        self.appProperties = appProperties
        self.encryption = encryption
        self.version = version
        self.spaceId = spaceId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.clientModifiedAt = clientModifiedAt
        self.deletedAt = deletedAt
        self.extra = extra
    }
}

extension SyncNode: Codable {
    private static let knownKeys: Set<String> = [
        "id", "spaceId", "kind", "parentId", "name", "mediaType", "blob",
        "appProperties", "encryption", "version", "createdAt", "updatedAt",
        "clientModifiedAt", "deletedAt"
    ]

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard let object = raw.objectValue else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "node is not a JSON object")
        }
        guard let id = object["id"]?.stringValue else {
            throw SyncError.malformedResponse("node without id")
        }
        self.id = id
        self.spaceId = object["spaceId"]?.stringValue
        self.kind = NodeKind(rawValue: object["kind"]?.stringValue ?? "file") ?? .file
        self.parentId = object["parentId"]?.stringValue
        self.name = object["name"]?.stringValue ?? ""
        self.mediaType = object["mediaType"]?.stringValue
        if let blobObject = object["blob"]?.objectValue,
           let blobID = blobObject["id"]?.stringValue {
            self.blob = BlobRef(id: blobID,
                                size: blobObject["size"]?.intValue ?? 0,
                                sha256: blobObject["sha256"]?.stringValue
                                    ?? Digest.bareHex(blobID))
        } else {
            self.blob = nil
        }
        self.appProperties = object["appProperties"]?.objectValue ?? [:]
        self.encryption = object["encryption"]
        self.version = object["version"]?.intValue ?? 0
        self.createdAt = object["createdAt"]?.stringValue
        self.updatedAt = object["updatedAt"]?.stringValue
        self.clientModifiedAt = object["clientModifiedAt"]?.stringValue
        self.deletedAt = object["deletedAt"]?.stringValue
        self.extra = object.filter { !SyncNode.knownKeys.contains($0.key) }
    }

    public func encode(to encoder: Encoder) throws {
        try json().encode(to: encoder)
    }

    /// The wire representation, with preserved unknown fields folded back in.
    public func json() -> JSONValue {
        var object = extra
        object["id"] = .string(id)
        object["kind"] = .string(kind.rawValue)
        object["name"] = .string(name)
        object["parentId"] = parentId.map { .string($0) } ?? .null
        object["mediaType"] = mediaType.map { .string($0) } ?? .null
        if let blob {
            object["blob"] = .object([
                "id": .string(blob.id),
                "size": .int(blob.size),
                "sha256": .string(blob.sha256)
            ])
        } else {
            object["blob"] = .null
        }
        object["appProperties"] = .object(appProperties)
        object["encryption"] = encryption ?? .null
        if let spaceId { object["spaceId"] = .string(spaceId) }
        if version > 0 { object["version"] = .int(version) }
        if let createdAt { object["createdAt"] = .string(createdAt) }
        if let updatedAt { object["updatedAt"] = .string(updatedAt) }
        if let clientModifiedAt { object["clientModifiedAt"] = .string(clientModifiedAt) }
        if let deletedAt { object["deletedAt"] = .string(deletedAt) }
        return .object(object)
    }

    /// The subset a mutation is allowed to declare — server-controlled fields
    /// like `version` and `updatedAt` are never sent back.
    public func mutationPayload() -> JSONValue {
        var object: [String: JSONValue] = [:]
        object["id"] = .string(id)
        object["kind"] = .string(kind.rawValue)
        object["parentId"] = parentId.map { .string($0) } ?? .null
        object["name"] = .string(name)
        object["mediaType"] = mediaType.map { .string($0) } ?? .null
        if let blob {
            object["blob"] = .object([
                "id": .string(blob.id),
                "size": .int(blob.size),
                "sha256": .string(blob.sha256)
            ])
        } else {
            object["blob"] = .null
        }
        object["appProperties"] = .object(appProperties)
        object["encryption"] = encryption ?? .null
        object["clientModifiedAt"] = .string(clientModifiedAt ?? SyncTime.string(Date()))
        return .object(object)
    }
}

// MARK: - Spaces and devices

public struct SyncSpace: Codable, Equatable, Sendable {
    public var id: String
    public var slug: String
    public var displayName: String
    public var rootNodeId: String
    public var quotaBytes: Int?
    public var usedBytes: Int?
    public var capabilities: [String]?

    public init(id: String, slug: String, displayName: String, rootNodeId: String,
                quotaBytes: Int? = nil, usedBytes: Int? = nil, capabilities: [String]? = nil) {
        self.id = id
        self.slug = slug
        self.displayName = displayName
        self.rootNodeId = rootNodeId
        self.quotaBytes = quotaBytes
        self.usedBytes = usedBytes
        self.capabilities = capabilities
    }
}

public struct SyncDevice: Codable, Equatable, Sendable {
    public var id: String
    public var installationId: String?
    public var name: String?
    public var platform: String?
    public var appId: String?
    public var scopes: [String]?
    public var createdAt: String?
    public var lastSeenAt: String?
}

public struct PairingRequest: Codable, Sendable {
    public var code: String
    public var deviceName: String
    public var deviceId: String
    public var platform: String
    public var appId: String
    public var appVersion: String

    public init(code: String, deviceName: String, deviceId: String,
                platform: String, appId: String, appVersion: String) {
        self.code = code
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.platform = platform
        self.appId = appId
        self.appVersion = appVersion
    }
}

public struct PairingResult: Codable, Sendable {
    public var token: String
    public var tokenType: String?
    public var device: SyncDevice
    public var spaces: [SyncSpace]
}

// MARK: - Snapshot and changes

public struct NodePage: Sendable {
    public var snapshotToken: String?
    public var snapshotCursor: String?
    public var nodes: [SyncNode]
    public var nextPageToken: String?

    public init(snapshotToken: String?, snapshotCursor: String?,
                nodes: [SyncNode], nextPageToken: String?) {
        self.snapshotToken = snapshotToken
        self.snapshotCursor = snapshotCursor
        self.nodes = nodes
        self.nextPageToken = nextPageToken
    }
}

extension NodePage: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        snapshotToken = raw["snapshotToken"]?.stringValue
        snapshotCursor = raw["snapshotCursor"]?.stringValue
        nextPageToken = raw["nextPageToken"]?.stringValue
        let items = raw["nodes"]?.arrayValue ?? []
        nodes = try items.map { try SyncNode(fromJSON: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var object: [String: JSONValue] = ["nodes": .array(nodes.map { $0.json() })]
        object["snapshotToken"] = snapshotToken.map { .string($0) } ?? .null
        object["snapshotCursor"] = snapshotCursor.map { .string($0) } ?? .null
        object["nextPageToken"] = nextPageToken.map { .string($0) } ?? .null
        try JSONValue.object(object).encode(to: encoder)
    }
}

public enum ChangeOperation: String, Codable, Sendable {
    case upsert, delete
}

public struct NodeChange: Sendable {
    public var cursor: String?
    public var operation: ChangeOperation
    public var nodeId: String
    public var node: SyncNode?

    public init(cursor: String?, operation: ChangeOperation, nodeId: String, node: SyncNode?) {
        self.cursor = cursor
        self.operation = operation
        self.nodeId = nodeId
        self.node = node
    }
}

public struct ChangePage: Sendable {
    public var changes: [NodeChange]
    public var nextCursor: String?
    public var hasMore: Bool

    public init(changes: [NodeChange], nextCursor: String?, hasMore: Bool) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

extension ChangePage: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        nextCursor = raw["nextCursor"]?.stringValue
        hasMore = raw["hasMore"]?.boolValue ?? false
        changes = try (raw["changes"]?.arrayValue ?? []).map { item in
            guard let nodeId = item["nodeId"]?.stringValue else {
                throw SyncError.malformedResponse("change without nodeId")
            }
            let op = ChangeOperation(rawValue: item["operation"]?.stringValue ?? "upsert") ?? .upsert
            let node = item["node"].flatMap { try? SyncNode(fromJSON: $0) }
            return NodeChange(cursor: item["cursor"]?.stringValue,
                              operation: op, nodeId: nodeId, node: node)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let items: [JSONValue] = changes.map { change in
            var object: [String: JSONValue] = [
                "operation": .string(change.operation.rawValue),
                "nodeId": .string(change.nodeId)
            ]
            object["cursor"] = change.cursor.map { .string($0) } ?? .null
            object["node"] = change.node?.json() ?? .null
            return .object(object)
        }
        var object: [String: JSONValue] = ["changes": .array(items), "hasMore": .bool(hasMore)]
        object["nextCursor"] = nextCursor.map { .string($0) } ?? .null
        try JSONValue.object(object).encode(to: encoder)
    }
}

// MARK: - Mutations

public enum MutationOperation: String, Codable, Sendable {
    case put, delete
}

public struct Mutation: Sendable {
    public var clientMutationId: String
    public var operation: MutationOperation
    public var baseVersion: Int?
    public var node: SyncNode?
    public var nodeId: String?
    public var recursive: Bool?

    public static func put(clientMutationId: String, node: SyncNode, baseVersion: Int?) -> Mutation {
        Mutation(clientMutationId: clientMutationId, operation: .put,
                 baseVersion: baseVersion, node: node, nodeId: nil, recursive: nil)
    }

    public static func delete(clientMutationId: String, nodeId: String,
                              baseVersion: Int?, recursive: Bool = false) -> Mutation {
        Mutation(clientMutationId: clientMutationId, operation: .delete,
                 baseVersion: baseVersion, node: nil, nodeId: nodeId, recursive: recursive)
    }

    public func json() -> JSONValue {
        var object: [String: JSONValue] = [
            "clientMutationId": .string(clientMutationId),
            "operation": .string(operation.rawValue),
            "baseVersion": baseVersion.map { .int($0) } ?? .null
        ]
        switch operation {
        case .put:
            object["node"] = node?.mutationPayload() ?? .null
        case .delete:
            object["nodeId"] = .string(nodeId ?? node?.id ?? "")
            object["recursive"] = .bool(recursive ?? false)
        }
        return .object(object)
    }
}

public enum MutationStatus: String, Codable, Sendable {
    case applied, duplicate, conflict, rejected
}

public struct MutationResult: Sendable {
    public var clientMutationId: String
    public var status: MutationStatus
    public var node: SyncNode?
    public var currentNode: SyncNode?
    public var problem: JSONValue?

    public init(clientMutationId: String, status: MutationStatus,
                node: SyncNode? = nil, currentNode: SyncNode? = nil,
                problem: JSONValue? = nil) {
        self.clientMutationId = clientMutationId
        self.status = status
        self.node = node
        self.currentNode = currentNode
        self.problem = problem
    }
}

public struct MutationResponse: Sendable {
    public var results: [MutationResult]
    public var nextCursor: String?

    public init(results: [MutationResult], nextCursor: String?) {
        self.results = results
        self.nextCursor = nextCursor
    }
}

extension MutationResponse: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        nextCursor = raw["nextCursor"]?.stringValue
        results = try (raw["results"]?.arrayValue ?? []).map { item in
            guard let id = item["clientMutationId"]?.stringValue else {
                throw SyncError.malformedResponse("result without clientMutationId")
            }
            let status = MutationStatus(rawValue: item["status"]?.stringValue ?? "") ?? .rejected
            return MutationResult(
                clientMutationId: id,
                status: status,
                node: item["node"].flatMap { try? SyncNode(fromJSON: $0) },
                currentNode: item["currentNode"].flatMap { try? SyncNode(fromJSON: $0) },
                problem: item["problem"])
        }
    }

    public func encode(to encoder: Encoder) throws {
        let items: [JSONValue] = results.map { result in
            var object: [String: JSONValue] = [
                "clientMutationId": .string(result.clientMutationId),
                "status": .string(result.status.rawValue)
            ]
            object["node"] = result.node?.json() ?? .null
            object["currentNode"] = result.currentNode?.json() ?? .null
            object["problem"] = result.problem ?? .null
            return .object(object)
        }
        var object: [String: JSONValue] = ["results": .array(items)]
        object["nextCursor"] = nextCursor.map { .string($0) } ?? .null
        try JSONValue.object(object).encode(to: encoder)
    }
}

// MARK: - Decoding helper

public extension SyncNode {
    /// Decodes from an already-parsed tree, so pages don't re-serialise.
    init(fromJSON value: JSONValue) throws {
        let data = CanonicalJSON.encode(value)
        self = try JSONDecoder().decode(SyncNode.self, from: data)
    }
}
