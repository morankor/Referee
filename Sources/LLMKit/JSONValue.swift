import Foundation

/// A JSON value: the request bodies LLMKit builds and the vendor events it reads, whose shapes vary from event to event.
/// Reading and writing go through JSONSerialization. Integers stay integers (`16000`, never `16000.0`) and booleans stay
/// booleans, so that a body can be compared exactly in a test.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// ---- reading a value ----

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// An integer, also when the vendor wrote it as a whole number with a fraction part (`90.0`).
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// The same object with `key` set to `value`; any other value is returned unchanged.
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }

    /// `self` with the top-level keys of `other` written over its own (plan section 5.3, `extraBodyJSON`). When either
    /// is not an object, `self` is returned unchanged.
    func merging(topLevelKeysOf other: JSONValue) -> JSONValue {
        guard case .object(var object) = self, case .object(let extra) = other else { return self }
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }
}

// ---- parsing and writing ----

extension JSONValue {
    /// The JSON in `data`, or nil when it is not JSON. Any byte sequence is safe to pass.
    static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(foundation: object)
    }

    static func parse<Text: StringProtocol>(_ text: Text) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// The value as JSON text: keys sorted, slashes not escaped, doubles in their shortest form (`0.2`, which
    /// JSONSerialization would write as `0.20000000000000001`).
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private init?(foundation value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(Int.max) {
                self = .double(number.doubleValue)          // an unsigned integer too large for Int
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var elements: [JSONValue] = []
            elements.reserveCapacity(array.count)
            for element in array {
                guard let converted = JSONValue(foundation: element) else { return nil }
                elements.append(converted)
            }
            self = .array(elements)
        case let dictionary as [String: Any]:
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let converted = JSONValue(foundation: element) else { return nil }
                object[key] = converted
            }
            self = .object(object)
        default:
            return nil
        }
    }

}

extension JSONValue: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)          // throws for NaN and infinity: never in a body
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
