import Foundation

/// URLSession implementation of `SyncTransport`.
///
/// TLS validation is left entirely alone — there is no delegate overriding
/// server trust, and no private CA is installed. The deployment presents a
/// publicly valid certificate, so the system default is exactly right.
public final class HTTPSyncTransport: SyncTransport, @unchecked Sendable {

    private let settings: SyncSettings
    private let credentials: CredentialStore
    private let session: URLSession

    public init(settings: SyncSettings, credentials: CredentialStore,
                session: URLSession? = nil) {
        self.settings = settings
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Request plumbing

    private func url(_ path: String, query: [String: String?] = [:]) throws -> URL {
        guard var components = URLComponents(
            url: settings.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false) else {
            throw SyncError.malformedResponse("bad URL for \(path)")
        }
        let items = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else {
            throw SyncError.malformedResponse("bad URL for \(path)")
        }
        return url
    }

    private func authorized(_ request: inout URLRequest) throws {
        guard let token = try credentials.token() else { throw SyncError.notPaired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Single round trip. Maps status codes onto `SyncError`; retry decisions
    /// belong to the caller so they can be scoped to a whole operation.
    @discardableResult
    private func send(_ request: URLRequest,
                      acceptableStatuses: Set<Int> = Set(200...299)) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SyncError.from(urlError: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.malformedResponse("non-HTTP response")
        }
        guard acceptableStatuses.contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let body = String(data: data.prefix(2048), encoding: .utf8) ?? ""
            // The server answers errors with RFC 7807 documents; prefer its own
            // `retryable` verdict over inferring one from the status code.
            let problem = ProblemDetails(data: data)
            var error = SyncError.from(status: http.statusCode, retryAfter: retryAfter,
                                       body: body, problem: problem)
            // tus reports the authoritative offset alongside 409/460.
            let serverOffset = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int.init)
            if case .offsetConflict = error { error = .offsetConflict(serverOffset: serverOffset) }
            if case .checksumMismatch = error { error = .checksumMismatch(serverOffset: serverOffset) }
            throw error
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.malformedResponse("\(type): \(error)")
        }
    }

    // MARK: - Capabilities

    /// Unauthenticated; reports the limits this deployment actually enforces.
    public func capabilities() async throws -> ServerCapabilities {
        let req = URLRequest(url: try url("v1/capabilities"))
        let (data, _) = try await send(req)
        return try decode(ServerCapabilities.self, from: data)
    }

    // MARK: - Pairing

    public func redeemPairing(_ request: PairingRequest) async throws -> PairingResult {
        var req = URLRequest(url: try url("v1/pairings/redeem"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        // Deliberately unauthenticated: this call is what mints the credential.
        let (data, _) = try await send(req)
        return try decode(PairingResult.self, from: data)
    }

    public func currentDevice() async throws -> SyncDevice {
        var req = URLRequest(url: try url("v1/devices/current"))
        try authorized(&req)
        let (data, _) = try await send(req)
        return try decode(SyncDevice.self, from: data)
    }

    public func revokeCurrentDevice() async throws {
        var req = URLRequest(url: try url("v1/devices/current"))
        req.httpMethod = "DELETE"
        try authorized(&req)
        try await send(req, acceptableStatuses: Set(200...299).union([404]))
    }

    public func spaces() async throws -> [SyncSpace] {
        var req = URLRequest(url: try url("v1/spaces"))
        try authorized(&req)
        let (data, _) = try await send(req)
        // Tolerate both a bare array and an envelope.
        if let list = try? JSONDecoder().decode([SyncSpace].self, from: data) { return list }
        let raw = try CanonicalJSON.decode(data)
        guard let items = raw["spaces"]?.arrayValue else {
            throw SyncError.malformedResponse("spaces payload")
        }
        return try items.map {
            try JSONDecoder().decode(SyncSpace.self, from: CanonicalJSON.encode($0))
        }
    }

    // MARK: - Snapshot and changes

    public func listNodes(spaceId: String, snapshotToken: String?,
                          pageToken: String?, limit: Int) async throws -> NodePage {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/nodes", query: [
            "snapshotToken": snapshotToken,
            "pageToken": pageToken,
            "limit": String(limit)
        ]))
        try authorized(&req)
        let (data, _) = try await send(req)
        return try decode(NodePage.self, from: data)
    }

    public func changes(spaceId: String, cursor: String?, limit: Int) async throws -> ChangePage {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/changes", query: [
            "cursor": cursor,
            "limit": String(limit)
        ]))
        try authorized(&req)
        let (data, _) = try await send(req)
        return try decode(ChangePage.self, from: data)
    }

    public func acknowledgeCursor(spaceId: String, cursor: String) async throws {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/cursor-acks"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = CanonicalJSON.encode(.object(["cursor": .string(cursor)]))
        try authorized(&req)
        try await send(req)
    }

    // MARK: - Blobs

    public func blobExists(spaceId: String, blobID: String) async throws -> Bool {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/blobs/\(blobPath(blobID))"))
        req.httpMethod = "HEAD"
        try authorized(&req)
        do {
            try await send(req)
            return true
        } catch SyncError.permanent(let status, _) where status == 404 {
            return false
        }
    }

    public func downloadBlob(spaceId: String, blobID: String, offset: Int) async throws -> Data {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/blobs/\(blobPath(blobID))"))
        try authorized(&req)
        if offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let (data, _) = try await send(req, acceptableStatuses: Set(200...299))
        return data
    }

    /// `sha256:<hex>` is a path segment; the colon must survive encoding.
    private func blobPath(_ blobID: String) -> String {
        blobID.hasPrefix("sha256:") ? blobID : "sha256:\(blobID)"
    }

    // MARK: - Resumable upload

    public func createUpload(spaceId: String, length: Int, sha256Hex: String) async throws -> UploadSession {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/uploads"))
        req.httpMethod = "POST"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(String(length), forHTTPHeaderField: "Upload-Length")
        // Base64 of the UTF-8 *hex string*, not of the raw digest bytes.
        let encodedDigest = Data(sha256Hex.utf8).base64EncodedString()
        req.setValue("sha256 \(encodedDigest)", forHTTPHeaderField: "Upload-Metadata")
        try authorized(&req)

        let (_, http) = try await send(req, acceptableStatuses: [201])
        guard let location = http.value(forHTTPHeaderField: "Location") else {
            throw SyncError.malformedResponse("upload without Location")
        }
        return UploadSession(location: location,
                             offset: http.value(forHTTPHeaderField: "Upload-Offset")
                                .flatMap(Int.init) ?? 0,
                             expiresAt: http.value(forHTTPHeaderField: "Upload-Expires"))
    }

    public func uploadOffset(location: String) async throws -> Int {
        var req = URLRequest(url: try resolve(location))
        req.httpMethod = "HEAD"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        try authorized(&req)
        let (_, http) = try await send(req)
        guard let offset = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int.init) else {
            throw SyncError.malformedResponse("HEAD without Upload-Offset")
        }
        return offset
    }

    public func appendChunk(location: String, offset: Int, data: Data) async throws -> Int {
        var req = URLRequest(url: try resolve(location))
        req.httpMethod = "PATCH"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        // Checksum covers this PATCH body only, as raw digest bytes base64'd.
        let chunkDigest = Data(Digest.hex(data).chunkedHexBytes).base64EncodedString()
        req.setValue("sha256 \(chunkDigest)", forHTTPHeaderField: "Upload-Checksum")
        req.httpBody = data
        try authorized(&req)

        let (_, http) = try await send(req, acceptableStatuses: [200, 204])
        return http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int.init)
            ?? (offset + data.count)
    }

    /// `Location` may be relative; resolve it against the configured base.
    private func resolve(_ location: String) throws -> URL {
        if let absolute = URL(string: location), absolute.scheme != nil { return absolute }
        guard let url = URL(string: location, relativeTo: settings.baseURL)?.absoluteURL else {
            throw SyncError.malformedResponse("unresolvable upload location \(location)")
        }
        return url
    }

    // MARK: - Mutations

    public func submit(spaceId: String, mutations: [Mutation], atomic: Bool,
                       idempotencyKey: String) async throws -> MutationResponse {
        var req = URLRequest(url: try url("v1/spaces/\(spaceId)/mutations"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        try authorized(&req)
        req.httpBody = CanonicalJSON.encode(.object([
            "atomic": .bool(atomic),
            "mutations": .array(mutations.map { $0.json() })
        ]))
        let (data, _) = try await send(req)
        return try decode(MutationResponse.self, from: data)
    }
}

private extension String {
    /// Hex string → the raw bytes it encodes.
    var chunkedHexBytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count / 2)
        var index = startIndex
        while index < endIndex, let next = self.index(index, offsetBy: 2, limitedBy: endIndex) {
            if let byte = UInt8(self[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }
}
