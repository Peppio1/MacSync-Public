import Foundation
import Security

public enum KeychainSecretError: Error, LocalizedError {
    case invalidSecret
    case unavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidSecret: return "Invalid or empty SMB password"
        case .unavailable(let code): return "macOS Keychain is unavailable (status \(code))"
        }
    }
}

/// Stores the original SMB password in the user's macOS Keychain rather than
/// UserDefaults, rclone.conf or the GitHub repository.
///
/// The prototype uses one local SMB connection profile. Never log its value.
public final class SMBSecretStore {
    private let service: String
    private let account: String

    public init(service: String = "com.macsync.prototype.smb", account: String = "primary") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func save(password: String) throws {
        guard !password.isEmpty, !password.contains("\n"), !password.contains("\r"),
              let data = password.data(using: .utf8) else {
            throw KeychainSecretError.invalidSecret
        }

        let updates: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw KeychainSecretError.unavailable(updated)
        }

        var creation = query
        creation[kSecValueData as String] = data
        creation[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(creation as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw KeychainSecretError.unavailable(added)
        }
    }

    public func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainSecretError.unavailable(status)
        }
        return password
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretError.unavailable(status)
        }
    }
}
