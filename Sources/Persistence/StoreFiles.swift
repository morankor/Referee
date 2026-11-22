import Foundation
import RefereeCore

// What the two file stores share: the one JSON format, the schema check of plan.md section 4.4, and the file
// operations of section 4.5 (durable writes, moving a damaged file aside).

/// The format of every file the stores write (plan.md sections 3.7 and 4.3): pretty-printed, sorted keys, slashes not
/// escaped, ISO 8601 dates.
enum StoreCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // A NaN or an infinity (a highlight rectangle of an empty PDF selection, a score of 0/0) would otherwise make
        // the whole session impossible to save. They are written as strings and read back as numbers.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }
}

/// What a file on disk turned out to hold.
enum StoreProbe<Value> {
    case value(Value)
    case newer(Int)          // a schemaVersion greater than this version supports; the file must not be touched
    case damaged             // not JSON, not an object, or not decodable as Value
}

enum StoreFiles {
    /// Plan section 4.4: read the file as `[String: Any]` and look at `schemaVersion` before decoding.
    static func probe<Value: Decodable>(_ type: Value.Type, from data: Data, supported: Int) -> StoreProbe<Value> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .damaged }
        if let version = object["schemaVersion"] as? Int, version > supported { return .newer(version) }
        guard let value = try? StoreCoding.decoder().decode(Value.self, from: data) else { return .damaged }
        return .value(value)
    }

    /// The same check without decoding, for a file about to be replaced: `.value(())` when it may be replaced and
    /// kept as the backup. Throws `StoreError.io` when the file exists but cannot be read.
    static func probeBeforeReplacing(_ url: URL, supported: Int) throws -> StoreProbe<Void> {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw StoreError.io("\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { return .damaged }
        return version > supported ? .newer(version) : .value(())
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Creates the folder and any missing parent, readable by the user only: review data holds quotes from the
    /// manuscript (plan section 12.4).
    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes `data` to `url`, replacing a file a crash may have left there, and flushes it to the disk before the
    /// caller renames it into place.
    static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Renames a file that could not be decoded to `<stem>-<UTC time><suffix>.json` in the same folder, so that no
    /// later save overwrites it, and returns where it now is. A second damaged file in the same second gets "-2", "-3"….
    static func quarantine(_ url: URL, stem: String, suffix: String = "", now: Date = Date()) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let base = "\(stem)-\(timestamp(now))\(suffix)"
        var target = folder.appendingPathComponent(base + ".json")
        var attempt = 1
        while exists(target) {
            attempt += 1
            let counter = attempt <= 1_000 ? "\(attempt)" : UUID().uuidString
            target = folder.appendingPathComponent("\(base)-\(counter).json")
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            throw StoreError.io("a damaged file could not be moved aside: \(error.localizedDescription)")
        }
        return target
    }

    /// "20261122T183012Z": ISO 8601 basic format, UTC, no colons (which Finder shows as slashes).
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter.string(from: date)
    }
}
