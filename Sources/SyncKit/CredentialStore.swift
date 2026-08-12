import Foundation
import Security

/// Where the device token lives. Abstracted so the acceptance suite can run
/// without touching the real Keychain — the handoff asks for exactly this
/// ("pairing and secure credential persistence abstraction").
public protocol CredentialStore: AnyObject, Sendable {
    func token() throws -> String?
    func setToken(_ token: String?) throws
}

/// macOS Keychain, generic password class.
///
/// The token never goes anywhere else: not UserDefaults, not the state file,
/// not logs, not URLs. `SyncState` holds only non-secret device/space metadata.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {

    private let service: String
    private let account: String

    public init(service: String = "com.natespaun.natesnotes.sync",
                account: String = "device-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func token() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setToken(_ token: String?) throws {
        guard let token else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        // Available after first unlock, but never syncs off this device.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}

/// Test double. Also useful as a fallback if the Keychain is unavailable, in
/// which case sync simply requires re-pairing on next launch rather than
/// writing the secret somewhere unsafe.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    public init(token: String? = nil) { self.value = token }

    public func token() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func setToken(_ token: String?) throws {
        lock.lock(); defer { lock.unlock() }
        value = token
    }
}
