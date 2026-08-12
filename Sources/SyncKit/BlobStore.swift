import Foundation

/// Content-addressed cache. Bytes only become visible under their digest after
/// size and SHA-256 both verify — the handoff is explicit that unverified bytes
/// must never be exposed as valid app content.
public final class BlobStore: @unchecked Sendable {

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(forDigest hex: String) -> URL {
        directory.appendingPathComponent(Digest.bareHex(hex))
    }

    public func has(_ blobID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forDigest: blobID).path)
    }

    public func data(for blobID: String) -> Data? {
        guard let data = try? Data(contentsOf: url(forDigest: blobID)) else { return nil }
        // Cheap insurance against a cache file corrupted after the fact.
        guard Digest.hex(data) == Digest.bareHex(blobID) else {
            try? FileManager.default.removeItem(at: url(forDigest: blobID))
            return nil
        }
        return data
    }

    /// Verifies then stores. Throws `corruptDownload` without publishing
    /// anything if the bytes don't match what was promised.
    @discardableResult
    public func store(_ data: Data, expecting blobID: String, expectedSize: Int? = nil) throws -> URL {
        let expected = Digest.bareHex(blobID)
        if let expectedSize, data.count != expectedSize {
            throw SyncError.corruptDownload(expected: "\(expectedSize) bytes",
                                            actual: "\(data.count) bytes")
        }
        let actual = Digest.hex(data)
        guard actual == expected else {
            throw SyncError.corruptDownload(expected: expected, actual: actual)
        }

        lock.lock(); defer { lock.unlock() }
        let destination = url(forDigest: expected)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let temp = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            // Lost a race with another writer; identical content, so accept it.
            try? FileManager.default.removeItem(at: temp)
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
        }
        return destination
    }

    /// Stores content this device authored — the digest is computed, not asserted.
    @discardableResult
    public func storeLocal(_ data: Data) throws -> BlobRef {
        let ref = BlobRef(data: data)
        try store(data, expecting: ref.id)
        return ref
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        let contents = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)
        for url in contents { try? FileManager.default.removeItem(at: url) }
    }
}
