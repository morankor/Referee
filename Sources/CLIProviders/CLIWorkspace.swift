import Foundation
import RefereeCore

/// The working directory of one run: `<TMPDIR>/referee-cli-<uuid>`, mode 0700, empty except for what the adapter
/// writes into it, removed when the run ends (plan.md sections 5.6.2 and 12.4).
struct CLIWorkspace: Sendable {
    static let prefix = "referee-cli-"

    /// The directory with symbolic links resolved (`/var/folders/…` is `/private/var/folders/…`), so that paths the CLI
    /// reports can be compared with it.
    let url: URL

    static func create(in root: URL) throws -> CLIWorkspace {
        let directory = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw LLMError.cliLaunchFailed("could not create a temporary working directory")
        }
        return CLIWorkspace(url: directory.resolvingSymlinksInPath())
    }

    /// Writes a file of the run (mode 0600) and returns its URL.
    @discardableResult
    func write(_ data: Data, named name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw LLMError.cliLaunchFailed("could not write a file into the temporary working directory")
        }
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes working directories that a crash left behind. Only directories older than `age` are touched, so that
    /// runs in progress (at most one hour, the total timeout) are never affected.
    static func removeStale(in root: URL, olderThan age: TimeInterval = 2 * 3600) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names where name.hasPrefix(prefix) {
            let path = root.appendingPathComponent(name).path
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
