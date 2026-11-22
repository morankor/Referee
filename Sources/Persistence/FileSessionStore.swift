import Foundation
import RefereeCore

/// Review sessions as files (plan.md sections 4.2 to 4.5). One folder per document, named by the SHA-256 of its bytes:
///
///     <directory>/<sha256>/session.json                          the session
///     <directory>/<sha256>/session.json.bak                      the version before the last save
///     <directory>/<sha256>/session.json.tmp                      only while a save is under way
///     <directory>/<sha256>/session.corrupt-<UTC time>.json       a session.json that could not be decoded, kept as it was
///     <directory>/<sha256>/session.corrupt-<UTC time>-backup.json   the same for a backup
///
/// Anything else in the folder belongs to the same document (ScholarKit keeps references.json there) and is deleted
/// with it. A key that is not a plain folder name (letters, digits, "-" and "_", at most 128) is refused, so that no
/// call can reach outside `directory` or remove `directory` itself.
public actor FileSessionStore: SessionStoring {     // <dataDirectory>/sessions
    /// The newest session format this version reads and writes (plan section 4.4).
    static let currentSchemaVersion = 1

    static let fileName = "session.json"
    static let backupName = "session.json.bak"
    static let temporaryName = "session.json.tmp"
    static let quarantineStem = "session.corrupt"

    private let directory: URL
    /// What the last load of each document repaired (plan section 4.5), for `recoveryNotice(sha256:)`.
    private var notices: [String: String] = [:]
    /// Tests only: runs after the new content is complete in session.json.tmp and before it is renamed into place.
    /// A throw there is a failure at the most delicate moment of a save.
    private let beforeReplacing: (@Sendable (URL) throws -> Void)?

    public init(directory: URL) {
        self.init(directory: directory, beforeReplacing: nil)
    }

    init(directory: URL, beforeReplacing: (@Sendable (URL) throws -> Void)?) {
        self.directory = directory
        self.beforeReplacing = beforeReplacing
    }

    /// nil when there is no session for this document. A session.json that does not decode is renamed
    /// session.corrupt-<time>.json and the backup is returned in its place; when there is no usable backup either,
    /// `StoreError.corrupt` names the renamed file. A file of a newer format throws `StoreError.newerSchema` and stays
    /// exactly as it is.
    public func loadSession(sha256: String) async throws -> ReviewSession? {
        notices[sha256] = nil
        let folder = try folder(for: sha256)
        let file = folder.appendingPathComponent(Self.fileName)
        let backup = folder.appendingPathComponent(Self.backupName)

        var damaged: URL?                    // where a damaged session.json was moved
        if StoreFiles.exists(file) {
            switch try read(file) {
            case .value(let session):
                return session
            case .newer(let found):
                Log.event("persistence.session.newerSchema", ["found": .int(found)])
                throw StoreError.newerSchema(found: found, supported: Self.currentSchemaVersion)
            case .damaged:
                damaged = try StoreFiles.quarantine(file, stem: Self.quarantineStem)
                Log.event("persistence.session.damaged", ["backup": .bool(StoreFiles.exists(backup))])
            }
        }

        // The backup stands in for a damaged session.json, and for a missing one: once a damaged file has been moved
        // aside, the backup is the latest good version until the next save.
        guard StoreFiles.exists(backup) else {
            if let damaged { throw StoreError.corrupt(path: damaged.path) }
            return nil
        }
        switch try read(backup) {
        case .value(let session):
            Log.event("persistence.session.restoredFromBackup", ["afterDamage": .bool(damaged != nil)])
            if let damaged {
                notices[sha256] = "The saved review was damaged, so its previous version was loaded from the backup. "
                    + "The damaged file was kept as \(damaged.lastPathComponent)."
            }
            return session
        case .newer(let found):
            Log.event("persistence.session.newerSchema", ["found": .int(found)])
            throw StoreError.newerSchema(found: found, supported: Self.currentSchemaVersion)
        case .damaged:
            let moved = try StoreFiles.quarantine(backup, stem: Self.quarantineStem, suffix: "-backup")
            Log.event("persistence.session.backupDamaged")
            throw StoreError.corrupt(path: (damaged ?? moved).path)
        }
    }

    /// Plan section 4.5: write session.json.tmp, then replace session.json with it, keeping the replaced file as
    /// session.json.bak (one backup). Never replaces a file of a newer format (throws `StoreError.newerSchema`), and
    /// never keeps a damaged session.json as the backup: it is moved aside first, as `loadSession` does.
    public func save(_ session: ReviewSession) async throws {
        let folder = try folder(for: session.document.sha256)
        let data: Data
        do {
            data = try StoreCoding.encoder().encode(session)
        } catch {
            throw StoreError.io("the review could not be encoded")
        }
        let file = folder.appendingPathComponent(Self.fileName)
        let temporary = folder.appendingPathComponent(Self.temporaryName)
        let manager = FileManager.default
        do {
            try StoreFiles.createDirectory(folder)
            if StoreFiles.exists(file) {
                switch try StoreFiles.probeBeforeReplacing(file, supported: Self.currentSchemaVersion) {
                case .value: break
                case .newer(let found):
                    Log.event("persistence.session.saveRefusedNewerSchema", ["found": .int(found)])
                    throw StoreError.newerSchema(found: found, supported: Self.currentSchemaVersion)
                case .damaged:
                    _ = try StoreFiles.quarantine(file, stem: Self.quarantineStem)
                    Log.event("persistence.session.damagedBeforeSave")
                }
            }
            try StoreFiles.writeDurably(data, to: temporary)
            do {
                try beforeReplacing?(temporary)
                if StoreFiles.exists(file) {
                    _ = try manager.replaceItemAt(file, withItemAt: temporary, backupItemName: Self.backupName,
                                                  options: [.withoutDeletingBackupItem])
                } else {
                    try manager.moveItem(at: temporary, to: file)
                }
            } catch {
                try? manager.removeItem(at: temporary)
                throw error
            }
        } catch let error as StoreError {
            throw error
        } catch {
            Log.event("persistence.session.saveFailed")
            throw StoreError.io("the review could not be saved: \(error.localizedDescription)")
        }
    }

    /// Set by `loadSession` when it loaded the backup because session.json was damaged; nil after a load that repaired
    /// nothing. (A session.json that is simply missing, after an earlier repair, is not reported again.)
    public func recoveryNotice(sha256: String) async -> String? {
        notices[sha256]
    }

    /// One summary per folder that holds a readable session (the backup when session.json is damaged or missing, as
    /// `loadSession` would return it), newest first. Reads only: nothing is renamed here. Folders without a session
    /// (a references.json alone), damaged ones and ones of a newer format are left out.
    public func listSessions() async -> [SessionSummary] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var summaries: [SessionSummary] = []
        for name in names where Self.isValidKey(name) {
            guard let session = peekSession(in: directory.appendingPathComponent(name, isDirectory: true)) else { continue }
            summaries.append(SessionSummary(id: name, fileName: session.document.fileName, title: session.meta.title,
                                            lastKnownPath: session.document.lastKnownPath, updatedAt: session.updatedAt,
                                            commentCount: session.comments.count,
                                            pendingCount: session.comments.filter { $0.status == .pending }.count,
                                            hasReport: session.report != nil))
        }
        return summaries.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    /// Removes the document's whole folder: session, backup, damaged copies and the reference lookups (plan section
    /// 4.2, "Delete Review Data…"). Deleting a document that has no folder is not an error.
    public func deleteSession(sha256: String) async throws {
        let folder = try folder(for: sha256)
        guard StoreFiles.exists(folder) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw StoreError.io("the review data could not be deleted: \(error.localizedDescription)")
        }
    }

    /// Removes every document folder (Settings ▸ Privacy, "Delete all review data…"): readable, damaged and newer ones
    /// alike. Only folders with a valid key are touched; anything else in `directory` stays.
    public func deleteAllSessions() async throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var failures = 0
        for name in names where Self.isValidKey(name) {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if (try? FileManager.default.removeItem(at: folder)) == nil { failures += 1 }
        }
        notices = [:]
        Log.event("persistence.session.deletedAll", ["failures": .int(failures)])
        if failures > 0 { throw StoreError.io("\(failures) review folder(s) could not be deleted") }
    }

    // ---- helpers ----

    /// A document's folder. The key is the hash of the PDF (64 lower-case hex digits); anything that is not a plain
    /// folder name is refused, so that "", "." or "../x" can never reach outside `directory` or remove it.
    private func folder(for key: String) throws -> URL {
        guard Self.isValidKey(key) else { throw StoreError.io("the document key is not valid") }
        return directory.appendingPathComponent(key, isDirectory: true)
    }

    static func isValidKey(_ key: String) -> Bool {
        let bytes = key.utf8
        return (1...128).contains(bytes.count) && bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    private func read(_ url: URL) throws -> StoreProbe<ReviewSession> {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw StoreError.io("\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
        return StoreFiles.probe(ReviewSession.self, from: data, supported: Self.currentSchemaVersion)
    }

    private func peekSession(in folder: URL) -> ReviewSession? {
        for name in [Self.fileName, Self.backupName] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            switch StoreFiles.probe(ReviewSession.self, from: data, supported: Self.currentSchemaVersion) {
            case .value(let session): return session
            case .newer: return nil
            case .damaged: continue
            }
        }
        return nil
    }
}
