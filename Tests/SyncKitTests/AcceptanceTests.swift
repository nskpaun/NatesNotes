import XCTest
@testable import SyncKit

/// The handoff's "minimum acceptance tests", numbered as written there.
final class AcceptanceTests: XCTestCase {

    var directory: URL!
    var server: FakeServer!
    var credentials: InMemoryCredentialStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synckit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = FakeServer()
        credentials = InMemoryCredentialStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func makeEngine(store: SyncStateStore? = nil) throws -> (SyncEngine, SyncStateStore) {
        let stateStore = try store ?? SyncStateStore(directory: directory)
        let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs"))
        let engine = SyncEngine(transport: server, store: stateStore, blobs: blobs,
                                credentials: credentials,
                                settings: SyncSettings(baseURL: URL(string: "https://example.invalid")!),
                                retry: .immediate,
                                pageLimit: 200)
        return (engine, stateStore)
    }

    /// A paired engine with its folders already established server-side.
    private func makePairedEngine() async throws -> (SyncEngine, SyncStateStore) {
        let (engine, store) = try makeEngine()
        _ = try await engine.pair(code: server.validCode, deviceName: "Test Mac")
        return (engine, store)
    }

    private func note(_ id: String, body: String) -> Data {
        CanonicalJSON.encode(.object([
            "schemaVersion": .int(1),
            "id": .string(id),
            "body": .string(body)
        ]))
    }

    // MARK: - 1. Pairing and secure credential persistence

    func test01_pairingStoresTokenOutsideAppState() async throws {
        let (engine, store) = try makeEngine()
        XCTAssertNil(try credentials.token())

        let space = try await engine.pair(code: server.validCode, deviceName: "Test Mac")

        XCTAssertEqual(space.slug, "natesnotes")
        XCTAssertNotNil(try credentials.token(), "token must land in the credential store")
        XCTAssertTrue(store.state.isPaired)
        XCTAssertEqual(store.state.spaceId, server.spaceId)

        // The secret must not be anywhere in the persisted app state.
        let stateData = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let stateText = String(data: stateData, encoding: .utf8) ?? ""
        let token = try XCTUnwrap(credentials.token())
        XCTAssertFalse(stateText.contains(token), "token leaked into app state")
    }

    func test01b_badPairingCodeIsForbiddenAndNotRetried() async throws {
        let (engine, store) = try makeEngine()
        do {
            _ = try await engine.pair(code: "WRONG", deviceName: "Test Mac")
            XCTFail("expected forbidden")
        } catch let error as SyncError {
            guard case .forbidden = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertFalse(store.state.isPaired)
        XCTAssertNil(try credentials.token())
        XCTAssertEqual(server.requestAttempts, 1, "a rejected code must not be retried")
    }

    // MARK: - 2. Multi-page first snapshot committed atomically

    func test02_multiPageSnapshotCommitsAtomically() async throws {
        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        for i in 0..<25 {
            server.seedFile(name: "n\(i).json", parentId: folder.id,
                            content: note("id-\(i)", body: "body \(i)"))
        }
        server.pageSize = 10

        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()

        XCTAssertGreaterThan(server.listNodeCalls, 2, "should have paged")
        // Root + notes folder + 25 files.
        XCTAssertEqual(store.state.mirror.count, 27)
        XCTAssertNotNil(store.state.lastCommittedCursor)
        XCTAssertTrue(server.acknowledgedCursors.contains(store.state.lastCommittedCursor!),
                      "cursor must be acknowledged only after the local commit")
    }

    func test02b_firstSyncDeliversExistingContentToANewDevice() async throws {
        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        for i in 0..<3 {
            server.seedFile(name: "n\(i).json", parentId: folder.id,
                            content: note("id-\(i)", body: "body \(i)"))
        }

        let (engine, _) = try await makePairedEngine()
        let outcome = try await engine.sync()

        XCTAssertEqual(outcome.updated.count, 3,
                       "a device pairing into a populated space must receive the content")
        let bodies = outcome.updated
            .compactMap { String(data: $0.content, encoding: .utf8) }
            .sorted()
        XCTAssertTrue(bodies.allSatisfy { $0.contains("body") })
        XCTAssertTrue(outcome.updated.allSatisfy { $0.folder == "notes" })
    }

    // MARK: - 3. Snapshot expiration (410) and restart

    func test03_snapshotExpiryRestartsCleanly() async throws {
        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        for i in 0..<15 {
            server.seedFile(name: "n\(i).json", parentId: folder.id,
                            content: note("id-\(i)", body: "b"))
        }
        server.pageSize = 5
        server.expireSnapshotAfterFirstPage = true

        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()

        // Restarted and completed; nothing partial was committed.
        XCTAssertEqual(store.state.mirror.count, 17)
        XCTAssertNotNil(store.state.lastCommittedCursor)
    }

    // MARK: - 4. Offline create/edit/delete surviving restart

    func test04_offlineIntentSurvivesRestart() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()

        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "offline"))

        // Simulate relaunch: brand-new store object over the same directory.
        let reopened = try SyncStateStore(directory: directory)
        XCTAssertTrue(reopened.state.outbox.contains { $0.recordKey == "note:a" },
                      "intent must be durable across restart")

        let (engine2, store2) = try makeEngine(store: reopened)
        _ = try await engine2.sync()

        XCTAssertTrue(store2.state.outbox.isEmpty, "outbox should drain once online")
        XCTAssertNotNil(server.node(named: "a.json",
                                    in: server.node(named: "notes", in: server.rootNodeId)!.id))
        _ = store
    }

    // MARK: - 5. Identical mutation and batch retries produce no duplicate work

    func test05_retriedBatchIsIdempotent() async throws {
        let (engine, _) = try await makePairedEngine()
        try await engine.takeSnapshot()
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "one"))
        _ = try await engine.sync()
        let filesAfterFirst = server.fileCount

        // Same logical work again: the server sees the same idempotency key for
        // an unchanged body and creates nothing new.
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "one"))
        _ = try await engine.sync()

        XCTAssertEqual(server.fileCount, filesAfterFirst, "no duplicate nodes")
    }

    // MARK: - 6. Incremental page application and cursor in one transaction

    func test06_incrementalPullCommitsPageAndCursorTogether() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()
        let baseCursor = store.state.lastCommittedCursor

        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        server.seedFile(name: "remote.json", parentId: folder.id,
                        content: note("remote", body: "from another device"))

        let outcome = try await engine.sync()

        XCTAssertEqual(outcome.updated.count, 1)
        XCTAssertEqual(outcome.updated.first?.name, "remote.json")
        XCTAssertNotEqual(store.state.lastCommittedCursor, baseCursor)
        XCTAssertTrue(server.acknowledgedCursors.contains(store.state.lastCommittedCursor!))

        // Replaying the same page must be harmless.
        let again = try await engine.sync()
        XCTAssertTrue(again.updated.isEmpty)
    }

    // MARK: - 7. Interrupted upload resumed at the server offset

    func test07_uploadResumesFromServerOffset() async throws {
        let (engine, _) = try await makePairedEngine()
        try await engine.takeSnapshot()

        // The server only accepts 100 bytes per PATCH, forcing several rounds.
        let big = Data((0..<1000).map { UInt8($0 % 251) })
        server.maxChunkAccepted = 100

        try await engine.enqueueUpsert(recordKey: "note:big", folder: "notes",
                                       fileName: "big.bin", mediaType: "application/octet-stream",
                                       appProperties: [:], content: big)
        _ = try await engine.sync()

        XCTAssertGreaterThanOrEqual(server.uploadPatchCalls, 10, "should have resumed repeatedly")
        let ref = BlobRef(data: big)
        XCTAssertEqual(server.blobs[ref.id], big, "reassembled bytes must match exactly")
    }

    func test07b_checksumRejectionRetransmitsFromServerOffset() async throws {
        let (engine, _) = try await makePairedEngine()
        try await engine.takeSnapshot()
        server.rejectNextChecksum = true

        let payload = Data("checksummed payload".utf8)
        try await engine.enqueueUpsert(recordKey: "note:c", folder: "notes",
                                       fileName: "c.json", mediaType: "application/json",
                                       appProperties: [:], content: payload)
        _ = try await engine.sync()

        XCTAssertEqual(server.blobs[BlobRef(data: payload).id], payload)
    }

    // MARK: - 8. Blob verification, including corrupt download failure

    func test08_verifiesDownloadedBytes() async throws {
        let blobs = try BlobStore(directory: directory.appendingPathComponent("verify"))
        let good = Data("hello".utf8)
        let ref = BlobRef(data: good)

        XCTAssertNoThrow(try blobs.store(good, expecting: ref.id, expectedSize: ref.size))
        XCTAssertEqual(blobs.data(for: ref.id), good)

        // Wrong bytes for that digest must be refused outright.
        XCTAssertThrowsError(try blobs.store(Data("tampered".utf8), expecting: ref.id)) { error in
            guard case SyncError.corruptDownload = error as? SyncError ?? .cancelled else {
                return XCTFail("expected corruptDownload, got \(error)")
            }
        }
        // Wrong length is caught too.
        XCTAssertThrowsError(try blobs.store(good, expecting: ref.id, expectedSize: 999))
    }

    func test08b_corruptServerDownloadFailsSyncWithoutPublishingBytes() async throws {
        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        server.seedFile(name: "x.json", parentId: folder.id, content: note("x", body: "real"))

        let (engine, _) = try await makePairedEngine()
        server.corruptDownloads = true

        do {
            _ = try await engine.sync()
            XCTFail("expected verification failure")
        } catch let error as SyncError {
            guard case .corruptDownload = error else {
                return XCTFail("expected corruptDownload, got \(error)")
            }
        }
    }

    // MARK: - 9. Rename/move preserves stable node identity

    func test09_renamePreservesNodeIdentity() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "v1"))
        _ = try await engine.sync()

        let notesFolder = try XCTUnwrap(server.node(named: "notes", in: server.rootNodeId))
        let original = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))

        // Same record, new name.
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: ["renamed": .bool(true)],
                                       content: note("a", body: "v2"))
        _ = try await engine.sync()

        let updated = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))
        XCTAssertEqual(updated.id, original.id, "node id must survive an update")
        XCTAssertGreaterThan(updated.version, original.version)
        XCTAssertEqual(store.state.mirror[original.id]?.version, updated.version)
    }

    // MARK: - 9b. A second write must not conflict with our own first one

    /// The regression behind the conflict-copy flood. An edit made while a write
    /// was in flight captured its `baseVersion` from the pre-push mirror. Both
    /// then went to the server together, the second carrying a version the first
    /// had already superseded — so the server refused it and the device recorded
    /// a conflict with nobody but itself.
    func test09b_secondWriteDoesNotConflictWithOurOwnFirst() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "v1"))
        _ = try await engine.sync()

        let notesFolder = try XCTUnwrap(server.node(named: "notes", in: server.rootNodeId))
        let v1 = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))

        // Queue an edit, then freeze it the way a push in progress would.
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "v2"))
        let inFlight = try XCTUnwrap(store.state.pendingItem(forRecord: "note:a"))
        try store.mutate { $0.updateOutboxItem(id: inFlight.id) { $0.status = .inFlight } }

        // The user keeps typing. This lands as its own item, and captures the
        // only version the mirror can offer — the one before v2 is applied.
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "v3"))
        let successor = try XCTUnwrap(store.state.pendingItem(forRecord: "note:a"))
        XCTAssertNotEqual(successor.id, inFlight.id, "an in-flight body is never rewritten")
        XCTAssertEqual(successor.baseVersion, v1.version, "queued against the pre-push version")

        _ = try await engine.sync()

        XCTAssertTrue(store.state.conflicts.filter { !$0.resolved }.isEmpty,
                      "a device must not conflict with its own previous write")
        XCTAssertTrue(store.state.outbox.isEmpty, "both writes should have landed")

        let final = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))
        XCTAssertEqual(final.id, v1.id, "still the same node")
        let blobId = try XCTUnwrap(final.blob?.id)
        XCTAssertEqual(server.blobs[blobId], note("a", body: "v3"),
                       "the later edit is what the server ends up holding")
    }

    // MARK: - 9c. Our own write, pulled back, is not a foreign edit

    /// The change feed replays what this device just wrote. Such a document must
    /// come back with a base equal to the bytes we pushed — that is the only
    /// thing telling the app's three-way merge that the "remote" side didn't
    /// move. Hand it a stale base and, with the user mid-edit, both sides look
    /// changed and the app manufactures a conflict against itself.
    func test09c_ownWriteReturnsWithAMatchingMergeBase() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()

        for body in ["v1", "v2", "v3"] {
            try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                           fileName: "a.json",
                                           mediaType: "application/json",
                                           appProperties: [:],
                                           content: note("a", body: body))
            let outcome = try await engine.sync()

            let notesFolder = try XCTUnwrap(server.node(named: "notes", in: server.rootNodeId))
            let node = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))
            let base = try XCTUnwrap(store.state.mirror[node.id]?.mergeBaseBlobId)
            XCTAssertEqual(base, BlobRef(data: note("a", body: body)).id,
                           "the merge base must track what we last pushed (\(body))")

            // If the feed replays our write, it must not look like someone
            // else's edit.
            for document in outcome.updated where document.nodeId == node.id {
                XCTAssertEqual(document.base, document.content,
                               "our own echo must arrive already reconciled (\(body))")
            }
            XCTAssertTrue(store.state.conflicts.filter { !$0.resolved }.isEmpty,
                          "pushing then pulling our own work is not a conflict (\(body))")
        }
    }

    // MARK: - 10. Tombstone application

    func test10_tombstonesArriveAsRemovals() async throws {
        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        let seeded = server.seedFile(name: "gone.json", parentId: folder.id,
                                     content: note("gone", body: "bye"))

        let (engine, store) = try await makePairedEngine()
        _ = try await engine.sync()

        // Another device deletes it.
        _ = try await server.submit(spaceId: server.spaceId,
                                    mutations: [.delete(clientMutationId: UUIDv7.string(),
                                                        nodeId: seeded.id,
                                                        baseVersion: seeded.version)],
                                    atomic: false, idempotencyKey: UUIDv7.string())

        let outcome = try await engine.sync()
        XCTAssertEqual(outcome.removed.first?.nodeId, seeded.id)
        XCTAssertEqual(outcome.removed.first?.folder, "notes")
        XCTAssertTrue(store.state.mirror[seeded.id]?.isTombstone ?? false)
    }

    // MARK: - 11. Expired change cursor causes a safe resnapshot

    func test11_expiredCursorTriggersResnapshot() async throws {
        let folder = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        server.seedFile(name: "a.json", parentId: folder.id, content: note("a", body: "one"))

        let (engine, store) = try await makePairedEngine()
        _ = try await engine.sync()
        let mirrorBefore = store.state.mirror.count

        // History gets trimmed past our cursor.
        server.seedFile(name: "b.json", parentId: folder.id, content: note("b", body: "two"))
        server.minimumValidCursor = 999

        let outcome = try await engine.sync()

        XCTAssertGreaterThanOrEqual(store.state.mirror.count, mirrorBefore + 1)
        XCTAssertTrue(outcome.updated.contains { $0.name == "b.json" },
                      "resnapshot should surface content we hadn't seen")
    }

    // MARK: - 12. Two-device stale-version conflict preserves both versions

    func test12_staleVersionConflictKeepsBothSides() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "original"))
        _ = try await engine.sync()

        let notesFolder = try XCTUnwrap(server.node(named: "notes", in: server.rootNodeId))
        let current = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))

        // Another device writes first, so our baseVersion goes stale.
        server.seedFile(name: "a.json", parentId: notesFolder.id,
                        content: note("a", body: "edited elsewhere"), nodeId: current.id)

        // Our local edit, still based on the old version.
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "edited here"))
        _ = try? await engine.sync()

        let conflicts = store.state.conflicts.filter { !$0.resolved }
        XCTAssertEqual(conflicts.count, 1, "the clash must be recorded, not swallowed")

        let conflict = try XCTUnwrap(conflicts.first)
        // Our version is preserved verbatim…
        let localBody = try XCTUnwrap(conflict.localContent)
        XCTAssertTrue(String(data: localBody, encoding: .utf8)!.contains("edited here"))
        // …and the server's version is still intact on the server.
        let serverNode = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))
        let serverBytes = try XCTUnwrap(server.blobs[serverNode.blob!.id])
        XCTAssertTrue(String(data: serverBytes, encoding: .utf8)!.contains("edited elsewhere"))

        // Resolving against the server's current version clears it.
        try await engine.resolveConflict(conflict.id,
                                         mergedContent: note("a", body: "merged by hand"))
        _ = try await engine.sync()

        let after = try XCTUnwrap(server.node(named: "a.json", in: notesFolder.id))
        let merged = try XCTUnwrap(server.blobs[after.blob!.id])
        XCTAssertTrue(String(data: merged, encoding: .utf8)!.contains("merged by hand"))
        XCTAssertTrue(store.state.conflicts.allSatisfy { $0.resolved })
    }

    // MARK: - 13. Revoked token returns to pairing without deleting local data

    func test13_revokedTokenReturnsToPairingKeepingLocalWork() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()
        try await engine.enqueueUpsert(recordKey: "note:keep", folder: "notes",
                                       fileName: "keep.json", mediaType: "application/json",
                                       appProperties: [:], content: note("keep", body: "unsent"))

        server.tokenRevoked = true

        do {
            _ = try await engine.sync()
            XCTFail("expected unauthorized")
        } catch let error as SyncError {
            XCTAssertEqual(error, .unauthorized)
        }

        XCTAssertNil(try credentials.token(), "revoked credential must be dropped")
        XCTAssertFalse(store.state.isPaired, "app returns to pairing")
        XCTAssertTrue(store.state.outbox.contains { $0.recordKey == "note:keep" },
                      "unsent local work must survive revocation")
        XCTAssertTrue(store.state.outbox.allSatisfy { $0.status == .pending },
                      "items should be replayable after re-pairing")
    }

    // MARK: - 14. Retry/backoff for timeouts, 429 and retryable 5xx

    func test14_retriesTransientFailures() async throws {
        let (engine, _) = try await makePairedEngine()
        server.failNextRequests = 2
        server.failureStatus = 503

        // Succeeds despite two injected 503s.
        try await engine.takeSnapshot()
        XCTAssertEqual(server.failNextRequests, 0)
    }

    func test14b_retryPolicyHonoursRetryAfterAndStopsOnPermanent() async throws {
        var delays: [TimeInterval] = []
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 30, jitter: { $0 })

        // 429 with Retry-After is respected.
        var attempts = 0
        let value: Int = try await withRetry(policy: policy, sleeper: { delays.append($0) }) {
            attempts += 1
            if attempts < 3 {
                throw SyncError.transient(status: 429, retryAfter: 2, detail: "slow down")
            }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(delays, [2, 2])

        // A permanent 4xx is not retried at all.
        var permanentAttempts = 0
        do {
            _ = try await withRetry(policy: policy, sleeper: { _ in }) {
                permanentAttempts += 1
                throw SyncError.permanent(status: 400, detail: "bad request")
            } as Int
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(permanentAttempts, 1)
        }

        // Exponential growth when the server gives no hint.
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: nil), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2, retryAfter: nil), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3, retryAfter: nil), 4)
        XCTAssertEqual(policy.delay(forAttempt: 9, retryAfter: nil), 30, "capped")
    }

    // MARK: - Mirrors of the live smoke test's two hardest phases

    /// Same sequence the live smoke test runs, so an ordering mistake in it
    /// shows up here rather than by burning a one-time pairing code.
    func test15_liveSmokeConflictSequence() async throws {
        let (engineA, storeA) = try await makePairedEngine()
        try await engineA.takeSnapshot()

        try await engineA.enqueueUpsert(recordKey: "note:x", folder: "notes",
                                        fileName: "x.json", mediaType: "application/json",
                                        appProperties: [:], content: note("x", body: "v1"))
        _ = try await engineA.sync()

        // Second install, no local state, same credential.
        let dirB = directory.appendingPathComponent("b")
        let storeB = try SyncStateStore(directory: dirB)
        let blobsB = try BlobStore(directory: dirB.appendingPathComponent("blobs"))
        let engineB = SyncEngine(transport: server, store: storeB, blobs: blobsB,
                                 credentials: credentials,
                                 settings: SyncSettings(baseURL: URL(string: "https://example.invalid")!),
                                 retry: .immediate)
        try await engineB.adoptPairing(spaceId: server.spaceId, rootNodeId: server.rootNodeId)
        _ = try await engineB.sync()

        // A pushes again, moving the server ahead of B.
        try await engineA.enqueueUpsert(recordKey: "note:x", folder: "notes",
                                        fileName: "x.json", mediaType: "application/json",
                                        appProperties: [:], content: note("x", body: "v2"))
        _ = try await engineA.sync()

        // B catches up and writes; then A writes from a stale base.
        _ = try await engineB.sync()
        try await engineB.enqueueUpsert(recordKey: "note:x", folder: "notes",
                                        fileName: "x.json", mediaType: "application/json",
                                        appProperties: [:], content: note("x", body: "from B"))
        _ = try await engineB.sync()

        try await engineA.enqueueUpsert(recordKey: "note:x", folder: "notes",
                                        fileName: "x.json", mediaType: "application/json",
                                        appProperties: [:], content: note("x", body: "from A"))
        _ = try? await engineA.sync()

        let open = storeA.state.conflicts.filter { !$0.resolved }
        XCTAssertEqual(open.count, 1, "A's stale write must conflict, not apply")
        XCTAssertEqual(open.first?.localContent, note("x", body: "from A"))

        // The server must still hold B's bytes.
        let folder = try XCTUnwrap(server.node(named: "notes", in: server.rootNodeId))
        let node = try XCTUnwrap(server.node(named: "x.json", in: folder.id))
        XCTAssertEqual(server.blobs[node.blob!.id], note("x", body: "from B"))

        // Resolving against the server's current version clears it.
        let merged = note("x", body: "merged")
        try await engineA.resolveConflict(try XCTUnwrap(open.first).id, mergedContent: merged)
        _ = try await engineA.sync()
        let after = try XCTUnwrap(server.node(named: "x.json", in: folder.id))
        XCTAssertEqual(server.blobs[after.blob!.id], merged)
        XCTAssertTrue(storeA.state.conflicts.allSatisfy(\.resolved))
    }

    func test16_liveSmokePagingSequence() async throws {
        let (engineA, storeA) = try await makePairedEngine()
        try await engineA.takeSnapshot()
        for i in 0..<4 {
            try await engineA.enqueueUpsert(recordKey: "note:\(i)", folder: "notes",
                                            fileName: "n\(i).json",
                                            mediaType: "application/json",
                                            appProperties: [:],
                                            content: note("n\(i)", body: "fixture \(i)"))
        }
        _ = try await engineA.sync()

        // A fresh install paging two nodes at a time must still end up complete.
        let dirC = directory.appendingPathComponent("c")
        let storeC = try SyncStateStore(directory: dirC)
        let blobsC = try BlobStore(directory: dirC.appendingPathComponent("blobs"))
        let engineC = SyncEngine(transport: server, store: storeC, blobs: blobsC,
                                 credentials: credentials,
                                 settings: SyncSettings(baseURL: URL(string: "https://example.invalid")!),
                                 retry: .immediate, pageLimit: 2)
        server.pageSize = 2
        try await engineC.adoptPairing(spaceId: server.spaceId, rootNodeId: server.rootNodeId)
        _ = try await engineC.sync()

        let expected = storeA.state.mirror.values.filter { !$0.isTombstone }.count
        let got = storeC.state.mirror.values.filter { !$0.isTombstone }.count
        XCTAssertEqual(got, expected, "paged snapshot must assemble completely")
        XCTAssertNotNil(storeC.state.lastCommittedCursor)
        XCTAssertGreaterThan(server.listNodeCalls, 2, "should have taken several pages")
    }

    // MARK: - Regression: intent queued before the tree is known

    /// Pairing enqueues the library *before* the first snapshot, so folder ids
    /// are guesses. If the space already holds `notes/` under a different id,
    /// every one of those items named a parent the server had never heard of
    /// and came back `parent_not_found` on every pass, forever.
    func test17_intentQueuedBeforeSnapshotIsRepointed() async throws {
        let existingNotes = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        server.seedFolder(name: "drawings", parentId: server.rootNodeId)

        let (engine, store) = try await makePairedEngine()

        for i in 0..<3 {
            try await engine.enqueueUpsert(recordKey: "note:\(i)", folder: "notes",
                                           fileName: "n\(i).json",
                                           mediaType: "application/json",
                                           appProperties: [:],
                                           content: note("n\(i)", body: "queued early"))
        }
        XCTAssertNotEqual(store.state.outbox.first { $0.kind == .putFile }?.parentId,
                          existingNotes.id,
                          "precondition: the queued parent is a provisional guess")

        _ = try await engine.sync()

        XCTAssertTrue(store.state.outbox.isEmpty,
                      "items must be re-pointed and drain, not strand")
        XCTAssertTrue(store.state.conflicts.filter { !$0.resolved }.isEmpty,
                      "an existing folder is not a content conflict")
        for i in 0..<3 {
            XCTAssertNotNil(server.node(named: "n\(i).json", in: existingNotes.id))
        }
    }

    /// The same repair has to rescue items already stranded on disk, since a
    /// shipped build meets users in that state. The subtle part: such an item
    /// was already submitted under its `clientMutationId`, so re-pointing it
    /// changes the body and needs a *fresh* id — reusing one earns
    /// `idempotency_mismatch`.
    func test18_strandedItemsRecoverWithAFreshMutationId() async throws {
        let realNotes = server.seedFolder(name: "notes", parentId: server.rootNodeId)
        let (engine, store) = try await makePairedEngine()

        try store.mutate { state in
            state.outbox = [OutboxItem(kind: .putFile, recordKey: "note:z",
                                       nodeId: UUIDv7.string(),
                                       parentId: UUIDv7.string(),   // never existed
                                       name: "z.json",
                                       mediaType: "application/json",
                                       content: self.note("z", body: "stranded"))]
        }
        let originalId = store.state.outbox.first?.id

        // Push while the tree is unknown: rejected, and the id is now spent.
        _ = try await engine.pushOutbox()
        XCTAssertEqual(store.state.outbox.first?.status, .blocked,
                       "precondition: a bad parent is rejected")

        // Now the app learns the real tree.
        _ = try await engine.sync()

        XCTAssertTrue(store.state.outbox.isEmpty,
                      "recovery must not loop on idempotency_mismatch")
        XCTAssertNotNil(server.node(named: "z.json", in: realNotes.id))
        _ = originalId
    }

    /// Recovery must not sweep up a genuine clash.
    func test19_realConflictsSurviveRecovery() async throws {
        let (engine, store) = try await makePairedEngine()
        try await engine.takeSnapshot()
        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "mine"))
        _ = try await engine.sync()

        let folder = try XCTUnwrap(server.node(named: "notes", in: server.rootNodeId))
        let current = try XCTUnwrap(server.node(named: "a.json", in: folder.id))
        server.seedFile(name: "a.json", parentId: folder.id,
                        content: note("a", body: "theirs"), nodeId: current.id)

        try await engine.enqueueUpsert(recordKey: "note:a", folder: "notes",
                                       fileName: "a.json", mediaType: "application/json",
                                       appProperties: [:], content: note("a", body: "mine again"))
        _ = try? await engine.sync()

        XCTAssertEqual(store.state.conflicts.filter { !$0.resolved }.count, 1)
        XCTAssertTrue(store.state.outbox.contains { $0.lastProblem == "conflict" },
                      "a real conflict stays parked for the user")
    }
}
