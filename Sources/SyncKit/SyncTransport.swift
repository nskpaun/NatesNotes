import Foundation

/// The whole network surface, as a protocol.
///
/// Domain code depends on this and never on a URL, which is what keeps the base
/// URL confined to the transport boundary. The acceptance suite substitutes an
/// in-process server implementing the same contract.
public protocol SyncTransport: Sendable {

    /// Deployed limits and features. Unauthenticated.
    func capabilities() async throws -> ServerCapabilities

    // Pairing and identity
    func redeemPairing(_ request: PairingRequest) async throws -> PairingResult
    func currentDevice() async throws -> SyncDevice
    func revokeCurrentDevice() async throws
    func spaces() async throws -> [SyncSpace]

    // Snapshot and changes
    func listNodes(spaceId: String, snapshotToken: String?,
                   pageToken: String?, limit: Int) async throws -> NodePage
    func changes(spaceId: String, cursor: String?, limit: Int) async throws -> ChangePage
    func acknowledgeCursor(spaceId: String, cursor: String) async throws

    // Blobs
    func blobExists(spaceId: String, blobID: String) async throws -> Bool
    func downloadBlob(spaceId: String, blobID: String, offset: Int) async throws -> Data

    // Resumable upload (tus)
    func createUpload(spaceId: String, length: Int, sha256Hex: String) async throws -> UploadSession
    func uploadOffset(location: String) async throws -> Int
    func appendChunk(location: String, offset: Int, data: Data) async throws -> Int

    // Mutations
    func submit(spaceId: String, mutations: [Mutation], atomic: Bool,
                idempotencyKey: String) async throws -> MutationResponse
}

/// What `GET /v1/capabilities` reports. Unknown fields are ignored; the engine
/// only needs the limits it has to stay inside.
public struct ServerCapabilities: Codable, Sendable, Equatable {
    public var apiVersion: String?
    public var maxJsonBodyBytes: Int?
    public var maxBlobBytes: Int?
    public var maxPageSize: Int?
    public var maxMutationBatch: Int?
    public var features: [String]?
    public var uploadProtocols: [String]?

    public init(maxPageSize: Int? = nil, maxMutationBatch: Int? = nil,
                features: [String]? = nil) {
        self.maxPageSize = maxPageSize
        self.maxMutationBatch = maxMutationBatch
        self.features = features
    }

    public func supports(_ feature: String) -> Bool {
        features?.contains(feature) ?? true
    }
}

public struct UploadSession: Sendable {
    public var location: String
    public var offset: Int
    public var expiresAt: String?

    public init(location: String, offset: Int, expiresAt: String?) {
        self.location = location
        self.offset = offset
        self.expiresAt = expiresAt
    }
}

/// Connection settings. The one place a base URL appears.
public struct SyncSettings: Sendable, Equatable {
    public var baseURL: URL
    public var appId: String
    public var appVersion: String
    public var platform: String
    public var spaceSlug: String
    public var uploadChunkSize: Int

    public init(baseURL: URL,
                appId: String = "com.natespaun.natesnotes",
                appVersion: String = "1.0.0",
                platform: String = "macOS",
                spaceSlug: String = "natesnotes",
                uploadChunkSize: Int = 4 << 20) {
        self.baseURL = baseURL
        self.appId = appId
        self.appVersion = appVersion
        self.platform = platform
        self.spaceSlug = spaceSlug
        self.uploadChunkSize = uploadChunkSize
    }

    /// Placeholder only. A real address is a fact about someone's network, so
    /// it is configured on the machine — see `standard()` — rather than
    /// compiled in where it would be published with the source. TLS validation
    /// is never bypassed whatever it is set to.
    public static let defaultBaseURL = URL(string: "https://sync.invalid")!

    /// Where the address is stored on this machine.
    public static let baseURLDefaultsKey = "nn.syncBaseURL"

    /// Environment first (a one-off run), then whatever the settings UI stored,
    /// then the compiled-in deployment above.
    public static func standard() -> SyncSettings {
        if let override = ProcessInfo.processInfo.environment["SYNC_BASE_URL"],
           let url = URL(string: override) {
            return SyncSettings(baseURL: url)
        }
        if let stored = UserDefaults.standard.string(forKey: baseURLDefaultsKey),
           let url = URL(string: stored), url.host != nil {
            return SyncSettings(baseURL: url)
        }
        return SyncSettings(baseURL: defaultBaseURL)
    }
}
