import Foundation
import Security
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// A Keychain that lives in memory and records every call; a test can make reads or writes fail.
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    enum Call: Equatable { case read, add(Data), update(Data), delete }

    private let lock = NSLock()
    private var item: Data?
    private var log: [Call] = []
    var readStatus: OSStatus?                 // set: every read returns this status (and no data)
    var writeStatus: OSStatus = errSecSuccess

    init(item: Data? = nil) { self.item = item }

    convenience init(secrets: [String: String]) {
        self.init(item: try? JSONEncoder().encode(secrets))
    }

    var calls: [Call] { lock.withLock { log } }
    var stored: [String: String]? { lock.withLock { item.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } } }
    var writes: [Call] { calls.filter { $0 != .read } }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            log.append(.read)
            if let readStatus { return (readStatus, nil) }
            guard let item else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, item)
        }
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            log.append(.add(data))
            guard writeStatus == errSecSuccess else { return writeStatus }
            guard item == nil else { return errSecDuplicateItem }
            item = data
            return errSecSuccess
        }
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            log.append(.update(data))
            guard writeStatus == errSecSuccess else { return writeStatus }
            guard item != nil else { return errSecItemNotFound }
            item = data
            return errSecSuccess
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            log.append(.delete)
            guard item != nil else { return errSecItemNotFound }
            item = nil
            return errSecSuccess
        }
    }
}

/// WP4 "secrets never lost" (plan section 5.8), with a fake backend; and "real Keychain", opt-in.
@Suite struct LLMKitSecretStoreTests {
    private func store(_ backend: FakeKeychain) -> KeychainSecretStore {
        KeychainSecretStore(service: "test.service", account: "secrets-v1", backend: backend)
    }

    @Test func aReadThatFailsWithErrSecAuthFailedWritesNothing() throws {
        let backend = FakeKeychain(secrets: ["openai-api": "o", "gemini-api": "g"])
        backend.readStatus = -25293                                 // errSecAuthFailed: a rebuilt app before approval
        let secrets = store(backend)
        #expect(throws: SecretError.unreadable(status: -25293)) { try secrets.setSecret("new", for: "anthropic-api") }
        #expect(throws: SecretError.unreadable(status: -25293)) { try secrets.setSecret(nil, for: "openai-api") }
        #expect(throws: SecretError.unreadable(status: -25293)) { try secrets.secret(for: "openai-api") }
        #expect(backend.writes.isEmpty)                             // no add, no update, no delete
        #expect(backend.stored == ["openai-api": "o", "gemini-api": "g"])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecNoSuchKeychain, errSecParam, -1])
    func anyOtherReadFailureWritesNothingEither(_ status: OSStatus) throws {
        let backend = FakeKeychain(secrets: ["openai-api": "o"])
        backend.readStatus = status
        #expect(throws: SecretError.unreadable(status: status)) { try store(backend).setSecret("new", for: "anthropic-api") }
        #expect(backend.writes.isEmpty)
    }

    @Test func noItemYetMeansAdd() throws {
        let backend = FakeKeychain()
        let secrets = store(backend)
        #expect(try secrets.secret(for: "anthropic-api") == nil)
        try secrets.setSecret("a-key", for: "anthropic-api")
        #expect(backend.writes == [.add(Data(#"{"anthropic-api":"a-key"}"#.utf8))])
        #expect(try secrets.secret(for: "anthropic-api") == "a-key")
        // Deleting a key from an item that does not exist writes nothing.
        let empty = FakeKeychain()
        try store(empty).setSecret(nil, for: "anthropic-api")
        #expect(empty.writes.isEmpty)
    }

    @Test func anItemThatWasReadIsUpdatedAndKeepsTheOtherKeys() throws {
        let backend = FakeKeychain(secrets: ["openai-api": "o", "gemini-api": "g"])
        let secrets = store(backend)
        try secrets.setSecret("a", for: "anthropic-api")
        #expect(backend.stored == ["openai-api": "o", "gemini-api": "g", "anthropic-api": "a"])
        try secrets.setSecret("o2", for: "openai-api")                       // replace
        #expect(backend.stored == ["openai-api": "o2", "gemini-api": "g", "anthropic-api": "a"])
        try secrets.setSecret(nil, for: "gemini-api")                        // remove one, keep the rest
        #expect(backend.stored == ["openai-api": "o2", "anthropic-api": "a"])
        try secrets.setSecret("", for: "openai-api")                         // an empty value removes too
        #expect(backend.stored == ["anthropic-api": "a"])
        #expect(backend.writes.allSatisfy { if case .update = $0 { return true } else { return false } })
        #expect(try secrets.secret(for: "anthropic-api") == "a")
        #expect(try secrets.secret(for: "xai-api") == nil)
    }

    @Test func anItemThatIsNotAJSONObjectIsUnreadableAndKept() throws {
        let backend = FakeKeychain(item: Data("not json".utf8))
        #expect(throws: SecretError.unreadable(status: errSecDecode)) { try store(backend).setSecret("a", for: "anthropic-api") }
        #expect(throws: SecretError.unreadable(status: errSecDecode)) { try store(backend).secret(for: "anthropic-api") }
        #expect(backend.writes.isEmpty)
    }

    @Test func aRejectedWriteIsWriteFailed() throws {
        let existing = FakeKeychain(secrets: ["openai-api": "o"])
        existing.writeStatus = errSecWrPerm
        #expect(throws: SecretError.writeFailed(status: errSecWrPerm)) { try store(existing).setSecret("a", for: "anthropic-api") }
        #expect(existing.stored == ["openai-api": "o"])
        let missing = FakeKeychain()
        missing.writeStatus = errSecNotAvailable
        #expect(throws: SecretError.writeFailed(status: errSecNotAvailable)) { try store(missing).setSecret("a", for: "anthropic-api") }
    }

    @Test func concurrentWritesOfDifferentKeysAreAllKept() async throws {
        let backend = FakeKeychain()
        let secrets = store(backend)
        let ids = (0..<24).map { "key-\($0)" }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? secrets.setSecret("value-\(id)", for: id) } }
        }
        #expect(backend.stored?.count == ids.count)
    }

    @Test func constructingAStoreReadsNothing() {
        // LiveDependencies builds the store at launch; the Keychain is asked only when a key is needed.
        let backend = FakeKeychain()
        _ = KeychainSecretStore(service: "test.service", account: "secrets-v1", backend: backend)
        #expect(backend.calls.isEmpty)
    }

    // ---- the real Keychain, opt-in ----

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REFEREE_TEST_KEYCHAIN"] == "1",
                   "Talks to the real Keychain; runs only with REFEREE_TEST_KEYCHAIN=1"))
    func theRealKeychainSetsGetsReplacesAndDeletes() throws {
        let service = "local.referee.tests.\(UUID().uuidString)"           // never the app's own item
        #expect(service != "local.referee.app")
        let secrets = KeychainSecretStore(service: service, account: "secrets-v1")
        defer {
            try? secrets.removeItem()
            let (status, _) = SecurityKeychainBackend().read(service: service, account: "secrets-v1")
            #expect(status == errSecItemNotFound, "the test item was not removed")
        }
        #expect(try secrets.secret(for: "anthropic-api") == nil)
        try secrets.setSecret("test-value-1", for: "anthropic-api")                // add
        #expect(try secrets.secret(for: "anthropic-api") == "test-value-1")
        try secrets.setSecret("test-value-2", for: "openai-api")                   // update, keeping the first
        try secrets.setSecret("test-value-3", for: "anthropic-api")                // replace
        #expect(try secrets.secret(for: "anthropic-api") == "test-value-3")
        #expect(try secrets.secret(for: "openai-api") == "test-value-2")
        try secrets.setSecret(nil, for: "anthropic-api")                           // delete one key
        #expect(try secrets.secret(for: "anthropic-api") == nil)
        #expect(try secrets.secret(for: "openai-api") == "test-value-2")
        // A second store on the same item sees the same keys.
        #expect(try KeychainSecretStore(service: service, account: "secrets-v1").secret(for: "openai-api") == "test-value-2")
    }
}
