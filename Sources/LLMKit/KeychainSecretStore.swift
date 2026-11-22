import Foundation
import RefereeCore
import Security

/// The API keys, in one generic-password item whose value is a UTF-8 JSON object mapping key names (the provider ids
/// `anthropic-api`, `openai-api`, `gemini-api`, `xai-api`) to secrets (plan section 5.8). One item rather than four,
/// because macOS asks before releasing each item to a rebuilt ad-hoc-signed app.
///
/// Read-modify-write never destroys keys: after a rebuild, reading fails with errSecAuthFailed (−25293) until the user
/// approves, while an update would succeed without approval. So `setSecret` writes only after the item was read
/// (then it updates) or is known not to exist (then it adds); on any other status it throws
/// `SecretError.unreadable` and writes nothing. The same holds for an item whose value is not such a JSON object.
public final class KeychainSecretStore: SecretStoring {
    private let service: String
    private let account: String
    private let backend: any KeychainBackend
    private let lock = NSLock()                    // one read-modify-write at a time within the app

    public convenience init(service: String = "local.referee.app", account: String = "secrets-v1") {
        self.init(service: service, account: account, backend: SecurityKeychainBackend())
    }

    init(service: String, account: String, backend: any KeychainBackend) {
        self.service = service
        self.account = account
        self.backend = backend
    }

    public func secret(for key: String) throws -> String? {
        try lock.withLock {
            try storedSecrets()?[key]
        }
    }

    /// nil (or an empty string) deletes the key; every other key is kept.
    public func setSecret(_ value: String?, for key: String) throws {
        try lock.withLock {
            let newValue = (value?.isEmpty ?? true) ? nil : value
            guard var secrets = try storedSecrets() else {
                // errSecItemNotFound: there is nothing to lose.
                guard let newValue else { return }
                try write(add: true, [key: newValue])
                return
            }
            guard secrets[key] != newValue else { return }
            secrets[key] = newValue
            try write(add: false, secrets)
        }
    }

    /// Removes the whole item. Only the opt-in test of the real Keychain uses it, to clean up after itself.
    func removeItem() throws {
        try lock.withLock {
            let status = backend.delete(service: service, account: account)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretError.writeFailed(status: status) }
        }
    }

    // ---- private ----

    /// The stored secrets; nil when the item does not exist. Throws `.unreadable` for every other outcome.
    private func storedSecrets() throws -> [String: String]? {
        let (status, data) = backend.read(service: service, account: account)
        switch status {
        case errSecSuccess:
            guard let data, !data.isEmpty else { return [:] }
            guard let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
                Log.event("secrets.unreadable", ["status": .int(Int(errSecDecode))])
                throw SecretError.unreadable(status: errSecDecode)
            }
            return secrets
        case errSecItemNotFound:
            return nil
        default:
            Log.event("secrets.unreadable", ["status": .int(Int(status))])
            throw SecretError.unreadable(status: status)
        }
    }

    private func write(add: Bool, _ secrets: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(secrets)
        } catch {
            throw SecretError.writeFailed(status: errSecParam)
        }
        let status = add ? backend.add(service: service, account: account, data: data)
                         : backend.update(service: service, account: account, data: data)
        guard status == errSecSuccess else {
            Log.event("secrets.write.failed", ["status": .int(Int(status))])
            throw SecretError.writeFailed(status: status)
        }
    }
}
