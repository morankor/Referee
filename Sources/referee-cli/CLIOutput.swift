import Foundation
import RefereeCore

/// Writing to the terminal. Everything a script reads goes to stdout; progress and errors go to stderr.
enum Output {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func raw(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// The JSON format of everything this project writes (plan section 3.7), on one line when `compact`.
    static func encoder(compact: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    static func json<T: Encodable>(_ value: T, compact: Bool = false) throws {
        var data = try encoder(compact: compact).encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// One JSON object per line, from a dictionary of JSON-compatible values.
    static func jsonLine(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// An Encodable value as a JSON-compatible object, for `jsonLine`.
    static func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? encoder(compact: true).encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    /// "exact", "fuzzy 0.91", "page only", "not found".
    static func confidence(_ confidence: AnchorConfidence) -> String {
        switch confidence {
        case .exact: return "exact"
        case .fuzzy(let score): return String(format: "fuzzy %.2f", score)
        case .pageOnly: return "page only"
        case .none: return "not found"
        }
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let value = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.1f", value)
    }

    static func status(_ status: RunStatus) -> String {
        switch status {
        case .running: return "running"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}
