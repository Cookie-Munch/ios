import Foundation
#if canImport(Security)
import Security
#endif

/// Pluggable persistence for the consent record. The equivalent of RN's `MobileStorage`
/// (the AsyncStorage-compatible interface). Ship the in-memory default for tests, the
/// UserDefaults store for a normal app, or the Keychain store when the record should be
/// held in the secure enclave-backed keychain.
public protocol ConsentStorage: Sendable {
    func getItem(_ key: String) async -> String?
    func setItem(_ key: String, _ value: String) async
    func removeItem(_ key: String) async
}

/// Volatile store — the default. Nothing survives process death; ideal for tests and
/// previews.
public actor InMemoryConsentStorage: ConsentStorage {
    private var store: [String: String] = [:]

    public init() {}

    public func getItem(_ key: String) async -> String? { store[key] }
    public func setItem(_ key: String, _ value: String) async { store[key] = value }
    public func removeItem(_ key: String) async { store[key] = nil }
}

/// `UserDefaults`-backed store — the conventional choice for a non-sensitive consent
/// record.
public struct UserDefaultsConsentStorage: ConsentStorage {
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        if let suiteName, let d = UserDefaults(suiteName: suiteName) { return d }
        return .standard
    }

    public func getItem(_ key: String) async -> String? { defaults.string(forKey: key) }
    public func setItem(_ key: String, _ value: String) async { defaults.set(value, forKey: key) }
    public func removeItem(_ key: String) async { defaults.removeObject(forKey: key) }
}

#if canImport(Security)
/// Keychain-backed secure store (Security framework). Stores the consent record as a
/// generic-password item, readable after first unlock, and not synced to iCloud by
/// default. Prefer this when your DPO wants the record held in the keychain rather than
/// in `UserDefaults`.
public struct KeychainConsentStorage: ConsentStorage {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.cookiemunch.consent", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func getItem(_ key: String) async -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setItem(_ key: String, _ value: String) async {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func removeItem(_ key: String) async {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
#endif
