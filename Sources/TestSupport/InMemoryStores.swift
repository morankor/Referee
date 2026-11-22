import Foundation
import RefereeCore

// Stores that keep everything in memory (plan.md section 10.3). They behave as the file stores do, as far as a caller
// can tell: a saved session comes back equal, the list is newest first, and nothing is ever written to disk.

public final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: ReviewSession] = [:]         // by document sha256
    private var saves = 0

    public init() {}

    /// How many times `save(_:)` has been called, whatever was saved. Not part of `SessionStoring`: it lets a test of
    /// the model's autosave see that several changes within the debounce gave one save (plan.md section 11.4, WP8b).
    public var saveCount: Int {
        lock.withLock { saves }
    }

    public func loadSession(sha256: String) async throws -> ReviewSession? {
        lock.withLock { sessions[sha256] }
    }

    public func save(_ session: ReviewSession) async throws {
        lock.withLock {
            sessions[session.document.sha256] = session
            saves += 1
        }
    }

    /// Newest first (by `updatedAt`).
    public func listSessions() async -> [SessionSummary] {
        let all = lock.withLock { Array(sessions.values) }
        return all
            .sorted { ($0.updatedAt, $0.document.sha256) > ($1.updatedAt, $1.document.sha256) }
            .map { session in
                SessionSummary(id: session.document.sha256, fileName: session.document.fileName, title: session.meta.title,
                               lastKnownPath: session.document.lastKnownPath, updatedAt: session.updatedAt,
                               commentCount: session.comments.count,
                               pendingCount: session.comments.filter { $0.status == .pending }.count,
                               hasReport: session.report != nil)
            }
    }

    public func deleteSession(sha256: String) async throws {
        lock.withLock { sessions[sha256] = nil }
    }
}

public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    public init(_ settings: AppSettings = DefaultSettings.make()) { self.settings = settings }

    public func load() async -> AppSettings {
        lock.withLock { settings }
    }

    public func save(_ settings: AppSettings) async throws {
        lock.withLock { self.settings = settings }
    }
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    private var failing = false

    public init(_ secrets: [String: String] = [:]) { self.secrets = secrets }

    /// The status a rebuilt, ad-hoc-signed app gets when it reads the Keychain item before the user has approved it
    /// (errSecAuthFailed, plan section 5.8).
    static let unreadableStatus: Int32 = -25293

    public var failReads: Bool {   // true: secret(for:) and setSecret throw SecretError.unreadable
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    public func secret(for key: String) throws -> String? {
        try lock.withLock {
            if failing { throw SecretError.unreadable(status: Self.unreadableStatus) }
            return secrets[key]
        }
    }

    /// nil deletes. While `failReads` is true nothing is changed, as the contract demands of a store that could not
    /// read its item.
    public func setSecret(_ value: String?, for key: String) throws {
        try lock.withLock {
            if failing { throw SecretError.unreadable(status: Self.unreadableStatus) }
            secrets[key] = value
        }
    }
}
