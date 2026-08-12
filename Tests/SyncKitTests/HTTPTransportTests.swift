import XCTest
import CryptoKit
@testable import SyncKit

/// Wire-format tests for `HTTPSyncTransport`.
///
/// The fake server used by the acceptance suite bypasses HTTP, so these stub at
/// the `URLProtocol` layer instead and assert the exact bytes and headers that
/// go out — the class of bug that would only show up against the real server.
final class HTTPTransportTests: XCTestCase {

    private var transport: HTTPSyncTransport!
    private var credentials: InMemoryCredentialStore!
    private let baseURL = URL(string: "https://sync.example.test")!

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
        credentials = InMemoryCredentialStore(token: "test-token")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        transport = HTTPSyncTransport(settings: SyncSettings(baseURL: baseURL),
                                      credentials: credentials,
                                      session: URLSession(configuration: config))
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Auth and pairing

    func testPairingPostsExpectedBodyWithoutBearer() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/pairings/redeem")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "pairing is what mints the credential; it must not send one")

            let body = try XCTUnwrap(request.bodyData)
            let json = try CanonicalJSON.decode(body)
            XCTAssertEqual(json["code"]?.stringValue, "ONE-TIME")
            XCTAssertEqual(json["appId"]?.stringValue, "com.natespaun.natesnotes")
            XCTAssertEqual(json["platform"]?.stringValue, "macOS")
            XCTAssertNotNil(json["deviceId"]?.stringValue)

            let payload = """
            {"token":"secret","tokenType":"Bearer",
             "device":{"id":"d1"},
             "spaces":[{"id":"s1","slug":"natesnotes","displayName":"N",
                        "rootNodeId":"r1"}]}
            """
            return (200, [:], Data(payload.utf8))
        }

        let result = try await transport.redeemPairing(
            PairingRequest(code: "ONE-TIME", deviceName: "Mac", deviceId: UUIDv7.string(),
                           platform: "macOS", appId: "com.natespaun.natesnotes",
                           appVersion: "1.0.0"))
        XCTAssertEqual(result.token, "secret")
        XCTAssertEqual(result.spaces.first?.rootNodeId, "r1")
    }

    func testAuthenticatedRequestsCarryBearerToken() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, [:], Data(#"{"id":"d1"}"#.utf8))
        }
        _ = try await transport.currentDevice()
    }

    func testMissingCredentialIsNotPaired() async {
        try? credentials.setToken(nil)
        do {
            _ = try await transport.currentDevice()
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? SyncError, .notPaired)
        }
    }

    // MARK: - Status mapping

    func testStatusCodesMapToTheRightErrors() async throws {
        func mappedError(status: Int, headers: [String: String] = [:]) async -> SyncError? {
            URLProtocolStub.handler = { _ in (status, headers, Data("{}".utf8)) }
            do {
                _ = try await transport.currentDevice()
                return nil
            } catch {
                return error as? SyncError
            }
        }

        let unauthorized = await mappedError(status: 401)
        XCTAssertEqual(unauthorized, .unauthorized)
        let gone = await mappedError(status: 410)
        XCTAssertEqual(gone, .gone(detail: "{}"))
        let forbidden = await mappedError(status: 403)
        if case .forbidden = forbidden {} else { XCTFail("403") }
        let missing = await mappedError(status: 404)
        if case .permanent(let code, _) = missing {
            XCTAssertEqual(code, 404)
        } else { XCTFail("404") }

        // 429 must surface Retry-After so backoff can honour it.
        let throttled = await mappedError(status: 429, headers: ["Retry-After": "7"])
        XCTAssertEqual(throttled?.retryAfter, 7)
        XCTAssertEqual(throttled?.isRetryable, true)

        let unavailable = await mappedError(status: 503)
        XCTAssertEqual(unavailable?.isRetryable, true)
    }

    // MARK: - Problem documents

    func testProblemDocumentIsParsedAndSurfaced() async {
        // The shape the live server actually returns.
        let payload = """
        {"type":"urn:personal-sync:problem:pairing-code-invalid",
         "title":"Pairing code is invalid","status":403,
         "detail":"The code is invalid, expired, or already used",
         "code":"pairing_code_invalid",
         "requestId":"019ff504-e1ce-7115-963a-a1d9cf96f911","retryable":false}
        """
        let problem = ProblemDetails(data: Data(payload.utf8))
        XCTAssertEqual(problem?.code, "pairing_code_invalid")
        XCTAssertEqual(problem?.requestId, "019ff504-e1ce-7115-963a-a1d9cf96f911")
        XCTAssertEqual(problem?.retryable, false)
        // The request id must survive into the message, so a failure in the
        // field can be matched against the server's log.
        XCTAssertTrue(problem!.summary.contains("019ff504-e1ce-7115-963a-a1d9cf96f911"))

        URLProtocolStub.handler = { _ in (403, [:], Data(payload.utf8)) }
        do {
            _ = try await transport.currentDevice()
            XCTFail("expected forbidden")
        } catch {
            guard case .forbidden(let detail) = error as? SyncError ?? .cancelled else {
                return XCTFail("expected forbidden, got \(error)")
            }
            XCTAssertTrue(detail.contains("pairing_code_invalid"))
        }

        XCTAssertNil(ProblemDetails(data: Data(#"{"nodes":[]}"#.utf8)),
                     "an ordinary payload is not a problem document")
    }

    func testServerRetryableFlagOverridesTheStatusCode() async {
        // A 500 the server says not to retry must not be retried…
        URLProtocolStub.handler = { _ in
            (500, [:], Data(#"{"code":"bad_request_shape","title":"Nope","retryable":false}"#.utf8))
        }
        var error = await capturedError()
        XCTAssertEqual(error?.isRetryable, false, "explicit retryable:false must win over 5xx")

        // …and a 400 it says *is* retryable should be.
        URLProtocolStub.handler = { _ in
            (400, [:], Data(#"{"code":"warming_up","title":"Try again","retryable":true}"#.utf8))
        }
        error = await capturedError()
        XCTAssertEqual(error?.isRetryable, true, "explicit retryable:true must win over 4xx")

        // 401 stays re-pairing regardless of what the body claims.
        URLProtocolStub.handler = { _ in
            (401, [:], Data(#"{"code":"authentication_required","retryable":true}"#.utf8))
        }
        error = await capturedError()
        XCTAssertEqual(error, .unauthorized)
    }

    private func capturedError() async -> SyncError? {
        do {
            _ = try await transport.currentDevice()
            return nil
        } catch {
            return error as? SyncError
        }
    }

    // MARK: - Capabilities

    func testCapabilitiesIsUnauthenticatedAndDecodes() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            // Verbatim from the live deployment.
            let payload = """
            {"apiVersion":"1","serverTime":"2026-08-12T08:08:42.186Z",
             "maxJsonBodyBytes":1048576,"maxBlobBytes":2147483648,
             "maxPageSize":500,"maxMutationBatch":100,
             "features":["snapshots","changes","events","range-download",
                         "resumable-upload","atomic-batch"],
             "uploadProtocols":["tus-1.0.0"]}
            """
            return (200, [:], Data(payload.utf8))
        }
        let caps = try await transport.capabilities()
        XCTAssertEqual(caps.maxPageSize, 500)
        XCTAssertEqual(caps.maxMutationBatch, 100)
        XCTAssertTrue(caps.supports("resumable-upload"))
        XCTAssertFalse(caps.supports("teleportation"))
    }

    // MARK: - Snapshot paging

    func testSnapshotPagingSendsBothTokensURLEncoded() async throws {
        URLProtocolStub.handler = { request in
            let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url),
                                                    resolvingAgainstBaseURL: false)?.queryItems)
            // The raw values must arrive intact even with URL-hostile characters.
            XCTAssertEqual(query.first { $0.name == "snapshotToken" }?.value, "tok en/+=")
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "page 2")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "200")
            return (200, [:], Data(#"{"snapshotToken":"t","snapshotCursor":"c","nodes":[],"nextPageToken":null}"#.utf8))
        }
        let page = try await transport.listNodes(spaceId: "s1", snapshotToken: "tok en/+=",
                                                 pageToken: "page 2", limit: 200)
        XCTAssertNil(page.nextPageToken)
        XCTAssertEqual(page.snapshotCursor, "c")
    }

    func testNodeDecodingPreservesUnknownFields() async throws {
        URLProtocolStub.handler = { _ in
            let payload = """
            {"snapshotToken":"t","snapshotCursor":"c","nextPageToken":null,"nodes":[
              {"id":"n1","kind":"file","parentId":"p1","name":"a.json","version":3,
               "mediaType":"application/json",
               "blob":{"id":"sha256:ab","size":12,"sha256":"ab"},
               "appProperties":{"entityType":"note"},
               "futureField":{"nested":true}}]}
            """
            return (200, [:], Data(payload.utf8))
        }
        let page = try await transport.listNodes(spaceId: "s1", snapshotToken: nil,
                                                 pageToken: nil, limit: 200)
        let node = try XCTUnwrap(page.nodes.first)
        XCTAssertEqual(node.version, 3)
        XCTAssertEqual(node.blob?.size, 12)
        XCTAssertEqual(node.appProperties["entityType"]?.stringValue, "note")
        // A field this client knows nothing about must survive a round trip.
        XCTAssertEqual(node.extra["futureField"]?["nested"]?.boolValue, true)
        let reencoded = node.json()
        XCTAssertEqual(reencoded["futureField"]?["nested"]?.boolValue, true)
    }

    // MARK: - Blobs

    func testResumedDownloadSendsRangeHeader() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=64-")
            XCTAssertTrue(request.url?.path.contains("sha256:") ?? false,
                          "blob id keeps its scheme prefix in the path")
            return (206, [:], Data("tail".utf8))
        }
        let data = try await transport.downloadBlob(spaceId: "s1",
                                                    blobID: "sha256:" + String(repeating: "a", count: 64),
                                                    offset: 64)
        XCTAssertEqual(String(data: data, encoding: .utf8), "tail")
    }

    func testBlobExistsIsFalseOn404() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            return (404, [:], Data())
        }
        let exists = try await transport.blobExists(spaceId: "s1", blobID: "sha256:abc")
        XCTAssertFalse(exists)
    }

    // MARK: - tus upload

    func testCreateUploadEncodesHexDigestAsBase64OfTheHexString() async throws {
        let payload = Data("hello world".utf8)
        let hex = Digest.hex(payload)

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Length"), "11")

            let metadata = try XCTUnwrap(request.value(forHTTPHeaderField: "Upload-Metadata"))
            let parts = metadata.split(separator: " ")
            XCTAssertEqual(String(parts[0]), "sha256")
            let decoded = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
            // The handoff is explicit: base64 of the 64-char lowercase hex
            // *string*, not of the 32 raw digest bytes.
            XCTAssertEqual(decoded.count, 64)
            XCTAssertEqual(String(data: decoded, encoding: .utf8), hex)

            return (201, ["Location": "/v1/spaces/s1/uploads/u1",
                          "Upload-Offset": "0",
                          "Upload-Expires": "2026-08-12T07:00:00.000Z"], Data())
        }

        let session = try await transport.createUpload(spaceId: "s1", length: payload.count,
                                                       sha256Hex: hex)
        XCTAssertEqual(session.location, "/v1/spaces/s1/uploads/u1")
        XCTAssertEqual(session.offset, 0)
    }

    func testPatchSendsRawDigestChecksumAndResolvesRelativeLocation() async throws {
        let chunk = Data("chunk bytes".utf8)

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            // A relative Location must resolve against the configured base URL.
            XCTAssertEqual(request.url?.absoluteString,
                           "https://sync.example.test/v1/spaces/s1/uploads/u1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Offset"), "128")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                           "application/offset+octet-stream")

            let checksum = try XCTUnwrap(request.value(forHTTPHeaderField: "Upload-Checksum"))
            let parts = checksum.split(separator: " ")
            XCTAssertEqual(String(parts[0]), "sha256")
            let decoded = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
            // The PATCH checksum is the raw 32-byte digest of this body.
            XCTAssertEqual(decoded.count, 32)
            XCTAssertEqual(Data(SHA256.hash(data: chunk)), decoded)

            XCTAssertEqual(request.bodyData, chunk)
            return (204, ["Upload-Offset": "139"], Data())
        }

        let offset = try await transport.appendChunk(location: "/v1/spaces/s1/uploads/u1",
                                                     offset: 128, data: chunk)
        XCTAssertEqual(offset, 139)
    }

    func testOffsetConflictCarriesServerOffset() async {
        URLProtocolStub.handler = { _ in (409, ["Upload-Offset": "512"], Data()) }
        do {
            _ = try await transport.appendChunk(location: "/u/1", offset: 0, data: Data("x".utf8))
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? SyncError, .offsetConflict(serverOffset: 512))
        }
    }

    func testChecksumFailureCarriesServerOffset() async {
        URLProtocolStub.handler = { _ in (460, ["Upload-Offset": "256"], Data()) }
        do {
            _ = try await transport.appendChunk(location: "/u/1", offset: 256, data: Data("x".utf8))
            XCTFail("expected checksum mismatch")
        } catch {
            XCTAssertEqual(error as? SyncError, .checksumMismatch(serverOffset: 256))
        }
    }

    // MARK: - Mutations

    func testMutationBatchCarriesIdempotencyKeyAndShape() async throws {
        let node = SyncNode(id: "n1", kind: .file, parentId: "p1", name: "a.json",
                            mediaType: "application/json",
                            blob: BlobRef(data: Data("x".utf8)),
                            appProperties: ["entityType": .string("note")])

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "batch-key-1")

            let body = try CanonicalJSON.decode(try XCTUnwrap(request.bodyData))
            XCTAssertEqual(body["atomic"]?.boolValue, false)
            let mutations = try XCTUnwrap(body["mutations"]?.arrayValue)
            XCTAssertEqual(mutations.count, 2)

            let put = mutations[0]
            XCTAssertEqual(put["operation"]?.stringValue, "put")
            XCTAssertEqual(put["baseVersion"], .null, "a create sends a null baseVersion")
            XCTAssertEqual(put["node"]?["name"]?.stringValue, "a.json")
            XCTAssertEqual(put["node"]?["blob"]?["size"]?.intValue, 1)
            XCTAssertNotNil(put["node"]?["clientModifiedAt"]?.stringValue)
            XCTAssertNil(put["node"]?["version"], "version is server-controlled")

            let delete = mutations[1]
            XCTAssertEqual(delete["operation"]?.stringValue, "delete")
            XCTAssertEqual(delete["nodeId"]?.stringValue, "n2")
            XCTAssertEqual(delete["baseVersion"]?.intValue, 4)
            XCTAssertEqual(delete["recursive"]?.boolValue, false)

            let payload = """
            {"results":[{"clientMutationId":"m1","status":"applied",
                         "node":{"id":"n1","version":5}},
                        {"clientMutationId":"m2","status":"conflict",
                         "currentNode":{"id":"n2","version":9}}],
             "nextCursor":"c9"}
            """
            return (200, [:], Data(payload.utf8))
        }

        let response = try await transport.submit(
            spaceId: "s1",
            mutations: [.put(clientMutationId: "m1", node: node, baseVersion: nil),
                        .delete(clientMutationId: "m2", nodeId: "n2", baseVersion: 4)],
            atomic: false,
            idempotencyKey: "batch-key-1")

        XCTAssertEqual(response.nextCursor, "c9")
        XCTAssertEqual(response.results[0].status, .applied)
        XCTAssertEqual(response.results[0].node?.version, 5)
        XCTAssertEqual(response.results[1].status, .conflict)
        XCTAssertEqual(response.results[1].currentNode?.version, 9)
    }

    func testCursorAckPostsCursor() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/spaces/s1/cursor-acks")
            let body = try CanonicalJSON.decode(try XCTUnwrap(request.bodyData))
            XCTAssertEqual(body["cursor"]?.stringValue, "cursor-9")
            return (204, [:], Data())
        }
        try await transport.acknowledgeCursor(spaceId: "s1", cursor: "cursor-9")
    }

    // MARK: - Canonical encoding

    func testCanonicalJSONIsByteStableAcrossOrderings() {
        let a = JSONValue.object(["b": .int(2), "a": .string("x"), "c": .array([.bool(true), .null])])
        let b = JSONValue.object(["c": .array([.bool(true), .null]), "a": .string("x"), "b": .int(2)])
        XCTAssertEqual(CanonicalJSON.encode(a), CanonicalJSON.encode(b))
        XCTAssertEqual(String(data: CanonicalJSON.encode(a), encoding: .utf8),
                       #"{"a":"x","b":2,"c":[true,null]}"#)
        // Identical content must therefore hash identically — the whole basis of
        // content addressing and upload dedup.
        XCTAssertEqual(Digest.blobID(for: CanonicalJSON.encode(a)),
                       Digest.blobID(for: CanonicalJSON.encode(b)))
    }

    func testCanonicalJSONEscapesControlCharacters() {
        let value = JSONValue.object(["s": .string("line\nbreak\ttab\"quote\\slash")])
        let encoded = String(data: CanonicalJSON.encode(value), encoding: .utf8)
        XCTAssertEqual(encoded, #"{"s":"line\nbreak\ttab\"quote\\slash"}"#)
        // And must survive a round trip unchanged.
        let decoded = try? CanonicalJSON.decode(CanonicalJSON.encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testUUIDv7HasVersionVariantAndOrdering() {
        let early = UUIDv7.generate(date: Date(timeIntervalSince1970: 1_000_000))
        let late = UUIDv7.generate(date: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertTrue(UUIDv7.isV7(early))
        XCTAssertTrue(UUIDv7.isV7(late))
        XCTAssertLessThan(early.uuidString, late.uuidString, "v7 sorts by time")
        XCTAssertEqual(UUIDv7.timestamp(of: late).timeIntervalSince1970, 2_000_000, accuracy: 0.01)
    }
}

// MARK: - Stub

final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession moves `httpBody` into a stream before it reaches URLProtocol,
    /// so read whichever one actually carries the bytes.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
