import Foundation
import RefereeCore

/// The debug transcript of plan.md section 10.5: with `REFEREE_DEBUG_DUMP=<dir>` every request's prompt and the raw
/// model output go to `<dir>/<timestamp>-<purpose>.txt`. Off unless the variable is set; the app's UI never sets it.
///
/// This is the only way manuscript text reaches a file other than the session, so the files are created readable by
/// their owner only (0600). A PDF part is noted with its size, not reproduced. Writing never fails a job.
struct DebugDump: Sendable {
    static let environmentVariable = "REFEREE_DEBUG_DUMP"
    let directory: URL?

    init(directory: URL?) { self.directory = directory }

    init(environment: [String: String]) {
        if let path = environment[Self.environmentVariable], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = nil
        }
    }

    var isOn: Bool { directory != nil }

    func write(request: LLMRequest, provider: ProviderRef, output: String, outcome: String) {
        guard let directory else { return }
        var text = "Human in the Loop debug transcript\npurpose: \(request.purpose.rawValue)\nprovider: \(provider.providerID)\n"
        text += "model: \(request.model ?? "(provider default)")\noutcome: \(outcome)\n"
        if let window = request.contextWindow { text += "context window: \(window)\n" }
        if let maximum = request.maxOutputTokens { text += "max output tokens: \(maximum)\n" }
        text += "\n=== system ===\n" + request.system + "\n"
        for (position, part) in request.parts.enumerated() {
            switch part {
            case .text(let body):
                text += "\n=== user turn, part \(position + 1): text ===\n" + body + "\n"
            case .pdf(let data, let fileName):
                text += "\n=== user turn, part \(position + 1): PDF \"\(fileName)\", \(data.count) bytes (not reproduced) ===\n"
            case .cacheBoundary:
                text += "\n=== user turn, part \(position + 1): cache boundary ===\n"
            }
        }
        text += "\n=== model output ===\n" + output + "\n"

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Self.timestamp()
            var url = directory.appendingPathComponent("\(stamp)-\(request.purpose.rawValue).txt")
            var counter = 1
            while manager.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(stamp).\(counter)-\(request.purpose.rawValue).txt")
                counter += 1
            }
            guard manager.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                Log.event("engine.debugdump.failed", ["purpose": .id(request.purpose.rawValue)])
                return
            }
            Log.event("engine.debugdump.written", ["purpose": .id(request.purpose.rawValue), "bytes": .int(text.utf8.count)])
        } catch {
            Log.event("engine.debugdump.failed", ["purpose": .id(request.purpose.rawValue)])
        }
    }

    /// "20261122T221530.123Z": UTC, sortable, no characters a file name cannot hold.
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: Date())
    }
}
