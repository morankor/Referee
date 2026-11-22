import Foundation

/// A response whose status is not 2xx (plan section 5.3): its status, its headers with lower-case names, and at most
/// 64 KB of its body. The adapter of the vendor turns it into an `LLMError` (section 5.5).
struct HTTPFailure: Error, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = Data(body.prefix(HTTPStreamClient.maxErrorBodyBytes))
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// `Retry-After`, in seconds: a number of seconds or an HTTP date. nil when the header is absent or unreadable.
    func retryAfter(now: Date = Date()) -> Double? {
        RetryAfter.seconds(header("retry-after"), now: now)
    }

    /// What the body says, read leniently.
    var vendorError: VendorError { VendorError(body: body) }
}

enum RetryAfter {
    /// "7" or "1.5" seconds, or an HTTP date as seconds from `now`; never negative. nil when absent or unreadable.
    static func seconds(_ value: String?, now: Date = Date()) -> Double? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) {
            return seconds.isFinite ? max(0, seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// What a vendor's error JSON says (plan section 5.5), read leniently from any of the shapes the five vendors use:
/// `{"error": {"type", "code", "message"}}` (Anthropic, OpenAI, Gemini), `{"error": "text"}` (Ollama, xAI),
/// `{"type", "code", "message"}` at the top level (OpenAI's stream `error` event), or plain text.
struct VendorError: Sendable, Equatable {
    var type: String?
    var code: String?               // only a string code: Google's numeric `code` repeats the HTTP status
    var message: String?

    static let maxMessageCharacters = 500

    init(type: String? = nil, code: String? = nil, message: String? = nil) {
        self.type = type; self.code = code; self.message = message
    }

    init(body: Data) {
        if let json = JSONValue.parse(body), json.objectValue != nil {
            self.init(json: json)
        } else {
            let text = String(decoding: body, as: UTF8.self)
            self.init(message: Self.clean(text))
        }
    }

    init(json: JSONValue) {
        let error = json["error"]
        if let text = error?.stringValue {
            self.init(type: json["type"]?.stringValue, code: json["code"]?.stringValue, message: Self.clean(text))
            return
        }
        let source: JSONValue
        if let error, error.objectValue != nil { source = error } else { source = json }
        self.init(type: source["type"]?.stringValue,
                  code: source["code"]?.stringValue,
                  message: Self.clean(source["message"]?.stringValue ?? json["message"]?.stringValue))
    }

    /// The message, else the type or code, else "HTTP <status>".
    func text(status: Int?) -> String {
        if let message { return message }
        if let code { return code }
        if let type { return type }
        return status.map { "HTTP \($0)" } ?? "unknown error"
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxMessageCharacters else { return trimmed }
        return String(trimmed.prefix(maxMessageCharacters)) + "…"
    }
}
