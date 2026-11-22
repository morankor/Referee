import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift): these stores keep nothing yet.

public final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    public init() {}

    public func loadSession(sha256: String) async throws -> ReviewSession? { nil }

    public func save(_ session: ReviewSession) async throws {}

    public func listSessions() async -> [SessionSummary] { [] }

    public func deleteSession(sha256: String) async throws {}
}

public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let initial: AppSettings

    public init(_ settings: AppSettings = DefaultSettings.make()) { initial = settings }

    public func load() async -> AppSettings { initial }

    public func save(_ settings: AppSettings) async throws {}
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    public init(_ secrets: [String: String] = [:]) {}

    public var failReads: Bool { get { false } set {} }   // true: secret(for:) and setSecret throw SecretError.unreadable

    public func secret(for key: String) throws -> String? { nil }

    public func setSecret(_ value: String?, for key: String) throws {}
}
