import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP8a replaces it with the file store of sections 4.2-4.5.

/// Placeholder: sessions are kept in memory for the life of this object. Nothing is read from or written to
/// `directory`, so a review does not survive closing the app yet.
public actor FileSessionStore: SessionStoring {     // <dataDirectory>/sessions
    private let directory: URL
    private var sessions: [String: ReviewSession] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    public func loadSession(sha256: String) async throws -> ReviewSession? {
        sessions[sha256]
    }

    public func save(_ session: ReviewSession) async throws {
        sessions[session.document.sha256] = session
    }

    /// Newest first.
    public func listSessions() async -> [SessionSummary] {
        sessions.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { session in
                SessionSummary(id: session.document.sha256, fileName: session.document.fileName, title: session.meta.title,
                               lastKnownPath: session.document.lastKnownPath, updatedAt: session.updatedAt,
                               commentCount: session.comments.count,
                               pendingCount: session.comments.filter { $0.status == .pending }.count,
                               hasReport: session.report != nil)
            }
    }

    public func deleteSession(sha256: String) async throws {
        sessions[sha256] = nil
    }
}
