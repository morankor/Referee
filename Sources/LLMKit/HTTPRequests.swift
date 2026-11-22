import Foundation
import RefereeCore

/// Building blocks of the adapters' requests (plan sections 5.3 and 5.4).
enum HTTPRequests {
    /// Every streaming request waits up to ten minutes for a byte, also on a session that is not the app's (section 5.3).
    static let streamTimeout: TimeInterval = 600
    /// Model lists and other small calls.
    static let listTimeout: TimeInterval = 30

    /// A POST of `body` as JSON, with `extraBodyJSON` merged in last.
    static func post(_ url: URL, body: JSONValue, extraBodyJSON: String?, headers: [(String, String)],
                     timeout: TimeInterval = streamTimeout) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            request.httpBody = try merged(body, extraBodyJSON: extraBodyJSON).data()
        } catch {
            throw LLMError.invalidRequest("the request could not be written as JSON")
        }
        return request
    }

    static func get(_ url: URL, headers: [(String, String)], timeout: TimeInterval = listTimeout) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// `ProviderSettings.extraBodyJSON`, when it parses as a JSON object, merged into the body: its top-level keys
    /// overwrite the body's (section 5.3). Anything else is ignored.
    static func merged(_ body: JSONValue, extraBodyJSON: String?) -> JSONValue {
        guard let text = extraBodyJSON, let extra = JSONValue.parse(text), extra.objectValue != nil else { return body }
        return body.merging(topLevelKeysOf: extra)
    }

    /// The model asked for: the request's, else the provider's setting.
    static func model(for request: LLMRequest, settings: ProviderSettings, provider: String) throws -> String {
        for candidate in [request.model, settings.model] {
            if let model = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty { return model }
        }
        throw LLMError.notConfigured("no model is chosen for \(provider)")
    }

    /// Output tokens asked for, when anyone asked: the request's, else the provider's setting.
    static func maxOutputTokens(_ request: LLMRequest, settings: ProviderSettings) -> Int? {
        request.maxOutputTokens ?? settings.maxOutputTokens
    }

    /// The text parts joined by blank lines, for the vendors that take one user message of text (xAI, Ollama). A PDF
    /// part is a programming error for them (sections 5.4.3 and 5.4.5).
    static func joinedText(_ parts: [LLMPart], provider: String) throws -> String {
        var texts: [String] = []
        for part in parts {
            switch part {
            case .text(let text): if !text.isEmpty { texts.append(text) }
            case .pdf: throw LLMError.invalidRequest("\(provider) does not accept PDF files; send the extracted text instead")
            case .cacheBoundary: continue
            }
        }
        return texts.joined(separator: "\n\n")
    }

    static func base64(_ data: Data) -> String {
        data.base64EncodedString()            // one line, no line breaks
    }
}

extension LLMError {
    /// The same error with every occurrence of `secret` in its message replaced, so that a vendor that echoes the key
    /// in an error cannot put it on screen (section 5.8).
    func removing(secret: String?) -> LLMError {
        guard let secret, secret.count >= 8 else { return self }
        func clean(_ text: String) -> String { text.replacingOccurrences(of: secret, with: "••••") }
        switch self {
        case .notConfigured(let m): return .notConfigured(clean(m))
        case .auth(let m): return .auth(clean(m))
        case .rateLimited(let t, let m): return .rateLimited(retryAfter: t, message: clean(m))
        case .quotaExhausted(let m): return .quotaExhausted(clean(m))
        case .contextTooLong(let m): return .contextTooLong(clean(m))
        case .invalidRequest(let m): return .invalidRequest(clean(m))
        case .modelNotFound(let m): return .modelNotFound(clean(m))
        case .refused(let m): return .refused(clean(m))
        case .network(let m): return .network(clean(m))
        case .server(let s, let m): return .server(status: s, message: clean(m))
        case .malformedResponse(let m): return .malformedResponse(clean(m))
        case .overloaded, .cliLaunchFailed, .cliTimeout, .cliExited, .toolUseBlocked, .cancelled: return self
        }
    }
}
