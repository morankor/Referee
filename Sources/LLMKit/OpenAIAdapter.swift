import Foundation
import RefereeCore

/// OpenAI Responses API (plan section 5.4.2). Chat Completions is not used for OpenAI.
struct OpenAIAdapter: HTTPProviderAdapter {
    let id: ProviderID = "openai-api"

    static let responsesURL = "https://api.openai.com/v1/responses"
    static let modelsURL = "https://api.openai.com/v1/models"
    /// Model ids containing any of these are hidden unless "Show all" is on.
    static let hiddenModelWords = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe", "moderation",
                                   "sora", "search", "computer-use"]
    /// 429 codes that mean the money or the quota is gone, not that the client is too fast (section 5.5).
    static let quotaCodes: Set<String> = ["credit_balance_exhausted", "insufficient_quota", "organization_usage_limit_exceeded"]

    func descriptor(settings: ProviderSettings) -> ProviderDescriptor {
        ProviderDescriptor(id: id, displayName: "OpenAI API", vendor: "OpenAI", authMode: .apiKey, isLocal: false,
                           destination: Endpoint.destination(Self.responsesURL, override: settings.baseURL), supportsNativePDF: true,
                           streaming: .token, retentionNote: "Sent with store=false; not kept for retrieval by the API.", isExperimental: false)
    }

    // ---- request ----

    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest {
        let model = try HTTPRequests.model(for: request, settings: settings, provider: "OpenAI API")
        var content: [JSONValue] = []
        for part in request.parts {
            switch part {
            case .text(let text):
                if !text.isEmpty { content.append(["type": "input_text", "text": .string(text)]) }
            case .pdf(let data, _):
                // The real file name is never sent (section 12.2).
                content.append(["type": "input_file", "filename": "manuscript.pdf",
                                "file_data": .string("data:application/pdf;base64," + HTTPRequests.base64(data))])
            case .cacheBoundary:
                continue                                        // prefix caching is automatic
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": true,
            "store": false,                                     // the default keeps responses for at least 30 days
            "input": [["role": "user", "content": .array(content)]],
        ]
        if !request.system.isEmpty { body["instructions"] = .string(request.system) }
        // Only when asked for: it counts reasoning tokens too, so the API's default is safer.
        if let maxTokens = HTTPRequests.maxOutputTokens(request, settings: settings) { body["max_output_tokens"] = .int(maxTokens) }
        return try HTTPRequests.post(Endpoint.resolve(Self.responsesURL, override: settings.baseURL), body: .object(body),
                                     extraBodyJSON: settings.extraBodyJSON,
                                     headers: [("Authorization", "Bearer \(secret ?? "")"), ("Content-Type", "application/json")])
    }

    // ---- stream ----

    func parse(line: String, state: inout StreamState) throws -> [LLMEvent] {
        let json: JSONValue
        switch SSE.classify(line) {
        case .ignored: return []
        case .done: return try finish(state: state)
        case .event(let value): json = value
        }
        switch json["type"]?.stringValue {
        case "response.created", "response.in_progress":
            return state.model(json["response"]?["model"]?.stringValue)         // the response object names its model (step 5c)
        case "response.output_text.delta":
            guard let delta = json["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]
        case "response.refusal.delta":
            state.refusal += json["delta"]?.stringValue ?? ""
            return []
        case "response.completed":
            remember(json["response"]?["usage"], in: &state)
            return state.model(json["response"]?["model"]?.stringValue) + [state.finished(state.refusal.isEmpty ? .endOfTurn : .refusal)]
        case "response.incomplete":
            remember(json["response"]?["usage"], in: &state)
            let named = state.model(json["response"]?["model"]?.stringValue)
            switch json["response"]?["incomplete_details"]?["reason"]?.stringValue {
            case "max_output_tokens": return named + [state.finished(.maxTokens)]
            case "content_filter": return named + [state.finished(.refusal)]
            default: return named + [state.finished(.other)]
            }
        case "response.failed":
            let error = json["response"]?["error"]
            throw Self.codeError(code: error?["code"]?.stringValue, message: error?["message"]?.stringValue)
        case "error":
            let vendor = VendorError(json: json)
            throw Self.codeError(code: vendor.code, message: vendor.message)
        default:
            return []
        }
    }

    private func remember(_ usage: JSONValue?, in state: inout StreamState) {
        guard let usage else { return }
        if let input = usage["input_tokens"]?.intValue { state.inputTokens = input }
        if let output = usage["output_tokens"]?.intValue { state.outputTokens = output }
    }

    // ---- errors (section 5.5) ----

    func mapFailure(_ failure: HTTPFailure) -> LLMError {
        let vendor = failure.vendorError
        let text = vendor.text(status: failure.status)
        let code = vendor.code ?? ""
        switch failure.status {
        case 401, 403:
            return .auth(text)
        case 429:
            return Self.isQuota(code) ? .quotaExhausted(text) : .rateLimited(retryAfter: failure.retryAfter(), message: text)
        case 404:
            return .modelNotFound(text)
        case 400 where code == "context_length_exceeded" || text.lowercased().contains("context"):
            return .contextTooLong(text)
        case 400..<500:
            return code == "model_not_found" ? .modelNotFound(text) : .invalidRequest(text)
        case 503 where code == "server_is_overloaded":
            return .overloaded(retryAfter: failure.retryAfter())
        default:
            return .server(status: failure.status, message: text)
        }
    }

    /// `response.failed` and the stream's `error` event carry a code and no HTTP status.
    static func codeError(code: String?, message: String?) -> LLMError {
        let text = message ?? code ?? "unknown error"
        guard let code else { return .server(status: 500, message: text) }
        if isQuota(code) { return .quotaExhausted(text) }
        switch code {
        case "rate_limit_exceeded": return .rateLimited(retryAfter: nil, message: text)
        case "server_is_overloaded": return .overloaded(retryAfter: nil)
        case "context_length_exceeded": return .contextTooLong(text)
        case "model_not_found": return .modelNotFound(text)
        case "invalid_api_key": return .auth(text)
        default: return code.hasPrefix("invalid_") ? .invalidRequest(text) : .server(status: 500, message: text)
        }
    }

    static func isQuota(_ code: String) -> Bool {
        quotaCodes.contains(code) || code.hasSuffix("_spend_limit_exceeded")
    }

    // ---- models ----

    /// Only `id`, `created` and `owned_by` exist: newest first, no context window, PDF support unknown.
    func listModels(client: HTTPStreamClient, settings: ProviderSettings, secret: String?, showAll: Bool) async throws -> [ModelInfo] {
        let url = try Endpoint.resolve(Self.modelsURL, override: settings.baseURL)
        let data = try await client.json(for: HTTPRequests.get(url, headers: [("Authorization", "Bearer \(secret ?? "")")]))
        let json = try ModelLists.decode(data)
        let dated = (json["data"]?.arrayValue ?? []).compactMap { item -> (model: ModelInfo, created: Int)? in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            return (ModelInfo(id: id, displayName: id), item["created"]?.intValue ?? 0)
        }
        let newestFirst = dated.sorted { ($0.created, $1.model.id) > ($1.created, $0.model.id) }.map(\.model)
        return ModelLists.hiding(newestFirst, idsContaining: Self.hiddenModelWords, showAll: showAll)
    }
}
