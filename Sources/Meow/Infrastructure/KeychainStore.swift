import Foundation
import Security

enum KeychainStore {
    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func credential(service: String, account: String) -> MigratingCredential {
        MigratingCredential(service: service, previousService: LegacyMigration.keychainService(for: service),
            read: { try read(service: $0, account: account) },
            write: { try write($1, service: $0, account: account) })
    }

    static func load(service: String, account: String) throws -> Data? {
        try credential(service: service, account: account).load()
    }

    static func save(_ value: Data, service: String, account: String) throws {
        try credential(service: service, account: account).save(value)
    }

    private static func read(service: String, account: String) throws -> Data? {
        var lookup = query(service: service, account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIKeyStore.Failure(status: status) }
        guard let value = result as? Data else { throw APIKeyStore.Failure(status: errSecDecode) }
        return value
    }

    private static func write(_ value: Data, service: String, account: String) throws {
        let lookup = query(service: service, account: account)
        let attributes = [kSecValueData as String: value]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = lookup.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecDuplicateItem {
                let updated = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
                guard updated == errSecSuccess else { throw APIKeyStore.Failure(status: updated) }
            } else if added != errSecSuccess { throw APIKeyStore.Failure(status: added) }
        } else if status != errSecSuccess { throw APIKeyStore.Failure(status: status) }
    }
}
