import Foundation
import RefereeCore

/// Anthropic Messages API (plan section 5.4.1).
struct AnthropicAdapter: HTTPProviderAdapter {
    let id: ProviderID = "anthropic-api"

    static let messagesURL = "https://api.anthropic.com/v1/messages"
    static let modelsURL = "https://api.anthropic.com/v1/models"
    static let apiVersion = "2026-10-21"

    func descriptor(settings: ProviderSettings) -> ProviderDescriptor {
        ProviderDescriptor(id: id, displayName: "Anthropic API", vendor: "Anthropic", authMode: .apiKey, isLocal: false,
                           destination: Endpoint.destination(Self.messagesURL, override: settings.baseURL), supportsNativePDF: true,
                           streaming: .token, retentionNote: "Sent to Anthropic under your API account's data terms.", isExperimental: false)
    }

    // ---- request ----

    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest {
        let model = try HTTPRequests.model(for: request, settings: settings, provider: "Anthropic API")
        var content: [JSONValue] = []
        var cacheMarked = false
        for part in request.parts {
            switch part {
            case .text(let text):
                if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
            case .pdf(let data, _):
                content.append(["type": "document",
                                "source": ["type": "base64", "media_type": "application/pdf", "data": .string(HTTPRequests.base64(data))]])
            case .cacheBoundary:
                // The block before the boundary is the end of the cached prefix; one boundary per request is honoured.
                if !cacheMarked, let last = content.indices.last {
                    content[last] = content[last].setting("cache_control", ["type": "ephemeral"])
                    cacheMarked = true
                }
            }
        }
        // max_tokens is required. The model's own limit comes from the cached model list, when there is one.
        let modelLimit = settings.cachedModels.first { $0.id == model }?.maxOutputTokens
        let maxTokens = HTTPRequests.maxOutputTokens(request, settings: settings) ?? min(modelLimit ?? 16_000, 32_000)
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "stream": true,
            "messages": [["role": "user", "content": .array(content)]],
        ]
        if !request.system.isEmpty { body["system"] = [["type": "text", "text": .string(request.system)]] }
        // Never temperature, top_p or top_k (API version 2026-10-21 rejects them on every model), and no thinking.
        return try HTTPRequests.post(Endpoint.resolve(Self.messagesURL, override: settings.baseURL), body: .object(body),
                                     extraBodyJSON: settings.extraBodyJSON,
                                     headers: [("x-api-key", secret ?? ""), ("anthropic-version", Self.apiVersion),
                                               ("content-type", "application/json")])
    }

    // ---- stream ----

    func parse(line: String, state: inout StreamState) throws -> [LLMEvent] {
        let json: JSONValue
        switch SSE.classify(line) {
        case .ignored: return []
        case .done: return try finish(state: state)           // [DONE] before message_stop: the stream ended early
        case .event(let value): json = value
        }
        switch json["type"]?.stringValue {
        case "message_start":
            if let usage = json["message"]?["usage"] { remember(usage, in: &state) }
            return state.model(json["message"]?["model"]?.stringValue)          // the model that answers (step 5c)
        case "content_block_delta":
            guard json["delta"]?["type"]?.stringValue == "text_delta",
                  let text = json["delta"]?["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue { state.stopReason = Self.stopReason(reason) }
            if let usage = json["usage"] { remember(usage, in: &state) }
            return []
        case "message_stop":
            return [state.finished()]
        case "error":
            let error = json["error"]
            throw Self.streamError(type: error?["type"]?.stringValue, message: error?["message"]?.stringValue)
        default:
            return []                                           // ping, content_block_start/stop, and anything new
        }
    }

    /// Input tokens include the cached prefix: `input_tokens` counts only what was neither written to nor read from
    /// the cache.
    private func remember(_ usage: JSONValue, in state: inout StreamState) {
        let inputParts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0]?.intValue }
        if !inputParts.isEmpty { state.inputTokens = inputParts.reduce(0, +) }
        if let output = usage["output_tokens"]?.intValue { state.outputTokens = output }
    }

    static func stopReason(_ reason: String) -> StopReason {
        switch reason {
        case "end_turn", "stop_sequence": return .endOfTurn
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        default: return .other
        }
    }

    // ---- errors (section 5.5) ----

    func mapFailure(_ failure: HTTPFailure) -> LLMError {
        let vendor = failure.vendorError
        let text = vendor.text(status: failure.status)
        let lower = text.lowercased()
        if vendor.type == "billing_error" { return .quotaExhausted(text) }
        switch failure.status {
        case 401, 403: return .auth(text)
        case 402: return .quotaExhausted(text)
        case 404: return .modelNotFound(text)
        case 413: return .contextTooLong(text)
        case 429: return .rateLimited(retryAfter: failure.retryAfter(), message: text)
        case 529: return .overloaded(retryAfter: failure.retryAfter())
        case 400:
            if lower.contains("spend limit") { return .quotaExhausted(text) }
            if Self.mentionsLength(lower) { return .contextTooLong(text) }
            return .invalidRequest(text)
        case 400..<500:
            return .invalidRequest(text)
        default:
            if vendor.type == "overloaded_error" { return .overloaded(retryAfter: failure.retryAfter()) }
            return .server(status: failure.status, message: text)
        }
    }

    /// An `error` event inside a 200 stream, mapped from `error.type`.
    static func streamError(type: String?, message: String?) -> LLMError {
        let text = message ?? type ?? "unknown error"
        let lower = text.lowercased()
        switch type {
        case "overloaded_error": return .overloaded(retryAfter: nil)
        case "rate_limit_error": return .rateLimited(retryAfter: nil, message: text)
        case "authentication_error", "permission_error": return .auth(text)
        case "billing_error": return .quotaExhausted(text)
        case "not_found_error": return .modelNotFound(text)
        case "request_too_large": return .contextTooLong(text)
        case "invalid_request_error":
            if lower.contains("spend limit") { return .quotaExhausted(text) }
            return mentionsLength(lower) ? .contextTooLong(text) : .invalidRequest(text)
        default: return .server(status: 500, message: text)    // api_error, timeout_error, and anything new
        }
    }

    private static func mentionsLength(_ lower: String) -> Bool {
        ["too long", "too large", "context", "token"].contains { lower.contains($0) }
    }

    // ---- models ----

    func listModels(client: HTTPStreamClient, settings: ProviderSettings, secret: String?, showAll: Bool) async throws -> [ModelInfo] {
        let base = try Endpoint.resolve(Self.modelsURL, override: settings.baseURL)
        let headers = [("x-api-key", secret ?? ""), ("anthropic-version", Self.apiVersion)]
        return try await ModelLists.paginate { afterID in
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            let data = try await client.json(for: HTTPRequests.get(Endpoint.adding(query, to: base), headers: headers))
            let json = try ModelLists.decode(data)
            let models = (json["data"]?.arrayValue ?? []).compactMap { item -> ModelInfo? in
                guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
                return ModelInfo(id: id, displayName: item["display_name"]?.stringValue ?? id,
                                 contextWindow: item["max_input_tokens"]?.intValue, maxOutputTokens: item["max_tokens"]?.intValue,
                                 supportsPDFInput: item["capabilities"]?["pdf_input"]?["supported"]?.boolValue)
            }
            let next = json["has_more"]?.boolValue == true ? json["last_id"]?.stringValue : nil
            return (models, next)
        }
    }
}
