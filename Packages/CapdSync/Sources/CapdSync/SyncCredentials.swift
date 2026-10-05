import Foundation
import Security

/// Public enrollment metadata. Credentials are stored separately from library databases.
public struct SyncEnrollment: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let binding: SyncLibraryBinding
    public let deviceID: UUID

    public init(endpoint: URL, binding: SyncLibraryBinding, deviceID: UUID) throws {
        try SyncEndpointPolicy.validate(endpoint)
        self.endpoint = endpoint
        self.binding = binding
        self.deviceID = deviceID
    }

    var credentialAccount: String {
        "\(binding.serviceID.uuidString)/\(binding.libraryID.uuidString)/\(deviceID.uuidString)"
    }
}

public protocol SyncCredentialStore: Sendable {
    func read(for enrollment: SyncEnrollment) throws -> String
    func save(_ credential: String, for enrollment: SyncEnrollment) throws
    func remove(for enrollment: SyncEnrollment) throws
}

/// Activation requires atomic creation, never a read-then-update of an existing account.
public protocol SyncCredentialCreationStore: SyncCredentialStore {
    /// Returns true only when this call created the credential. An identical existing
    /// value returns false; different or unreadable existing credentials are refused.
    func insertIfAbsent(_ credential: String, for enrollment: SyncEnrollment) throws -> Bool
}

enum SyncCredentialValidation {
    static func check(_ credential: String) throws {
        guard !credential.isEmpty, credential.utf8.count <= 4_089,
            credential.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw SyncConnectionError.invalidCredential }
    }
}

public struct KeychainSyncCredentialStore: SyncCredentialCreationStore {
    private let service: String

    public init(service: String) {
        precondition(!service.isEmpty)
        self.service = service
    }

    private func query(_ enrollment: SyncEnrollment) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: enrollment.credentialAccount,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func read(for enrollment: SyncEnrollment) throws -> String {
        var lookup = query(enrollment)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, let token = String(data: data, encoding: .utf8)
        else { throw SyncConnectionError.credentialUnavailable }
        try SyncCredentialValidation.check(token)
        return token
    }

    public func save(_ credential: String, for enrollment: SyncEnrollment) throws {
        try SyncCredentialValidation.check(credential)
        let values: [String: Any] = [
            kSecValueData as String: Data(credential.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let lookup = query(enrollment)
        let status = SecItemUpdate(lookup as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = lookup
            item.merge(values) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SyncConnectionError.credentialUnavailable
            }
        } else if status != errSecSuccess {
            throw SyncConnectionError.credentialUnavailable
        }
    }

    public func insertIfAbsent(_ credential: String, for enrollment: SyncEnrollment) throws -> Bool
    {
        try SyncCredentialValidation.check(credential)
        var item = query(enrollment)
        item[kSecValueData as String] = Data(credential.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { throw SyncConnectionError.credentialUnavailable }
        guard try read(for: enrollment) == credential else {
            throw SyncConnectionError.invalidCredential
        }
        return false
    }

    public func remove(for enrollment: SyncEnrollment) throws {
        let status = SecItemDelete(query(enrollment) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncConnectionError.credentialUnavailable
        }
    }
}

/// Disposable credential storage for synthetic tests and setup previews.
public final class MemorySyncCredentialStore: SyncCredentialCreationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: String] = [:]

    public init() {}

    public func read(for enrollment: SyncEnrollment) throws -> String {
        try lock.withLock {
            guard let credential = credentials[enrollment.credentialAccount] else {
                throw SyncConnectionError.credentialUnavailable
            }
            return credential
        }
    }

    public func save(_ credential: String, for enrollment: SyncEnrollment) throws {
        try SyncCredentialValidation.check(credential)
        lock.withLock { credentials[enrollment.credentialAccount] = credential }
    }

    public func insertIfAbsent(_ credential: String, for enrollment: SyncEnrollment) throws -> Bool
    {
        try SyncCredentialValidation.check(credential)
        return try lock.withLock {
            if let prior = credentials[enrollment.credentialAccount] {
                guard prior == credential else { throw SyncConnectionError.invalidCredential }
                return false
            }
            credentials[enrollment.credentialAccount] = credential
            return true
        }
    }

    public func remove(for enrollment: SyncEnrollment) throws {
        _ = lock.withLock { credentials.removeValue(forKey: enrollment.credentialAccount) }
    }
}
