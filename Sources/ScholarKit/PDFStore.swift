import Foundation
import RefereeCore

/// Downloaded open-access PDFs in `<cacheDirectory>/papers/<sha256(url)>.pdf` (plan.md section 8.7), least recently
/// used first out once the folder is over the limit. A file's modification date is the time it was last handed
/// out. Downloads in progress are hidden files ending in `.partial` in the same folder.
struct PDFStore: Sendable {
    /// `<cacheDirectory>/papers`
    let directory: URL

    /// Bytes in a megabyte of `ReferenceSettings.pdfCacheLimitMB` (decimal, as the Finder counts).
    static let bytesPerMB: Int64 = 1_000_000
    /// A partial file this old is left over from a download that never finished (the app quit or crashed).
    static let abandonedPartialAge: TimeInterval = 3_600

    func file(for url: URL) -> URL {
        directory.appendingPathComponent(ReferenceText.sha256Hex(url.absoluteString) + ".pdf", isDirectory: false)
    }

    func contains(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    /// Marks a file as just used.
    func touch(_ file: URL, at date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    /// A new, empty partial file for a download.
    func newPartialFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw ResolverError.downloadFailed("it could not be saved")
        }
        return partial
    }

    /// Moves a finished download into place (an existing file of the same name is replaced atomically).
    func install(_ partial: URL, as file: URL, at date: Date) throws {
        guard rename(partial.path, file.path) == 0 else { throw ResolverError.downloadFailed("it could not be saved") }
        touch(file, at: date)
    }

    func discard(_ partial: URL) {
        try? FileManager.default.removeItem(at: partial)
    }

    /// Deletes the least recently used PDFs until the folder holds at most `limitBytes`, never `kept` (the file just
    /// handed out). Abandoned partial files go too.
    func evict(limitBytes: Int64, keeping kept: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var cached: [(file: URL, size: Int64, used: Date)] = []
        for file in contents {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let used = values.contentModificationDate ?? .distantPast
            if file.lastPathComponent.hasSuffix(".partial") {
                if Date().timeIntervalSince(used) > Self.abandonedPartialAge { discard(file) }
                continue
            }
            guard file.pathExtension == "pdf" else { continue }
            cached.append((file, Int64(values.fileSize ?? 0), used))
        }
        var total = cached.reduce(Int64(0)) { $0 + $1.size }
        let oldestFirst = cached.sorted { ($0.used, $0.file.lastPathComponent) < ($1.used, $1.file.lastPathComponent) }
        var evicted = 0
        for item in oldestFirst where total > limitBytes && item.file.lastPathComponent != kept.lastPathComponent {
            guard (try? FileManager.default.removeItem(at: item.file)) != nil else { continue }
            total -= item.size
            evicted += 1
        }
        if evicted > 0 { Log.event("scholar.pdf.evicted", ["files": .int(evicted)]) }
    }
}
