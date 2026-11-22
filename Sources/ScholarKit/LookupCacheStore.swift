import Foundation
import RefereeCore

/// The lookups made for one manuscript, in `<dataDirectory>/sessions/<sha256>/references.json` (plan.md sections 4.2
/// and 8.7): in the manuscript's own folder, so that deleting the review deletes them. Keyed by the SHA-256 of the
/// folded entry text; resolved lookups are kept 180 days, `notFound` 30 days, `failed` never.
struct LookupCacheStore: Sendable {
    static let fileName = "references.json"
    static let schemaVersion = 1
    static let resolvedLifetime: TimeInterval = 180 * 86_400
    static let notFoundLifetime: TimeInterval = 30 * 86_400

    /// `<dataDirectory>/sessions`
    let sessionsDirectory: URL

    /// What is written: `{"lookups": {<key>: ResolvedReference}, "schemaVersion": 1}`.
    private struct File: Codable {
        var schemaVersion: Int
        var lookups: [String: ResolvedReference]
    }

    /// The key of an entry: the SHA-256 of its folded `rawText`.
    static func key(for entry: BibEntry) -> String {
        ReferenceText.sha256Hex(ReferenceText.fold(entry.rawText))
    }

    /// A document id names a folder, so only plain letters and digits are used as one (a SHA-256 in hex is). For
    /// anything else nothing is cached, in memory or on disk.
    static func isUsableDocumentID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Whether a cached lookup still counts at `now`.
    static func isFresh(_ reference: ResolvedReference, now: Date) -> Bool {
        let age = now.timeIntervalSince(reference.resolvedAt)
        switch reference.status {
        case .resolved: return age <= resolvedLifetime
        case .notFound: return age <= notFoundLifetime
        case .failed: return false
        }
    }

    func folder(for document: String) -> URL {
        sessionsDirectory.appendingPathComponent(document, isDirectory: true)
    }

    func file(for document: String) -> URL {
        folder(for: document).appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The fresh lookups of a document; empty when the file is missing, unreadable or of another format.
    func load(_ document: String, now: Date) -> [String: ResolvedReference] {
        guard let data = try? Data(contentsOf: file(for: document)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(File.self, from: data), stored.schemaVersion == Self.schemaVersion else {
            Log.event("scholar.cache.unreadable")
            return [:]
        }
        return stored.lookups.filter { Self.isFresh($0.value, now: now) }
    }

    /// Writes the file atomically, creating the document's folder (mode 0700) when it is missing.
    func save(_ lookups: [String: ResolvedReference], for document: String) throws {
        let folder = folder(for: document)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(schemaVersion: Self.schemaVersion, lookups: lookups))
        try data.write(to: file(for: document), options: [.atomic])
    }

    /// Deletes the file, and the document's folder when nothing else is left in it (`rmdir` removes only an empty
    /// folder, so a session saved there at the same moment is never touched).
    func remove(_ document: String) {
        try? FileManager.default.removeItem(at: file(for: document))
        _ = folder(for: document).withUnsafeFileSystemRepresentation { path in
            path.map { rmdir($0) }
        }
    }
}
