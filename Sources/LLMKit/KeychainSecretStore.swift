import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP4 replaces it with the Keychain item of section 5.8.

/// Placeholder: secrets are kept in memory for the life of the process. Nothing is read from or written to the
/// Keychain, so no build of Wave 0 can trigger a Keychain prompt or touch a stored key.
public final class KeychainSecretStore: SecretStoring {
    private let service: String
    private let account: String
    private let memory = SecretMemory()

    public init(service: String = "local.referee.app", account: String = "secrets-v1") {
        self.service = service
        self.account = account
    }

    public func secret(for key: String) throws -> String? {
        memory.value(for: key)
    }

    public func setSecret(_ value: String?, for key: String) throws {
        memory.set(value, for: key)
    }
}

private final class SecretMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func value(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return secrets[key]
    }

    func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        secrets[key] = value
    }
}
