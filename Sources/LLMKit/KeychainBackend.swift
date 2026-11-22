import Foundation
import Security

/// The four Keychain calls of the secret store, behind a protocol so that a test can make them fail (plan section 5.8).
/// All four address one generic-password item by service and account.
protocol KeychainBackend: Sendable {
    /// SecItemCopyMatching for the item's data.
    func read(service: String, account: String) -> (status: OSStatus, data: Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// The real Keychain: the login keychain of the user who runs the app, as an ad-hoc-signed app without entitlements
/// can use it.
struct SecurityKeychainBackend: KeychainBackend {
    private func item(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        var query = item(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var attributes = item(service, account)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(item(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(item(service, account) as CFDictionary)
    }
}
