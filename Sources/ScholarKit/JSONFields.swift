import Foundation

/// Lenient reading of service JSON: a field of an unexpected type reads as absent, so an odd record never fails a
/// whole answer (plan.md section 2.5: parsers of untrusted input are total).
typealias JSONObject = [String: Any]

enum JSONFields {
    /// The top-level object of a body, or nil when the body is not a JSON object.
    static func object(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }

    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }

    func array(_ key: String) -> [Any]? { self[key] as? [Any] }

    /// A whole number, also when the service wrote it as 1997.0.
    func int(_ key: String) -> Int? { JSONFields.int(self[key]) }
}

extension JSONFields {
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) < 1e9 else { return nil }
        return Int(double)
    }
}
