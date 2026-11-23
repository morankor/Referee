import Foundation
import RefereeCore

/// xAI Chat Completions (plan section 5.4.3): text only, data-only SSE, errors told apart by HTTP status alone.
/// If xAI retires this endpoint, `xai-api` moves to the OpenAI Responses adapter with base URL `https://api.x.ai/v1`
/// and `store: false` (R12).
struct XAIAdapter: HTTPProviderAdapter {
    let id: ProviderID = "xai-api"

    static let completionsURL = "https://api.x.ai/v1/chat/completions"
    static let modelsURL = "https://api.x.ai/v1/models"

    func descriptor(settings: ProviderSettings) -> ProviderDescriptor {
        ProviderDescriptor(id: id, displayName: "xAI API", vendor: "xAI", authMode: .apiKey, isLocal: false,
                           destination: Endpoint.destination(Self.completionsURL, override: settings.baseURL), supportsNativePDF: false,
                           streaming: .token, retentionNote: "Sent to an endpoint that does not store requests.", isExperimental: false)
    }

    // ---- request ----

    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest {
        let model = try HTTPRequests.model(for: request, settings: settings, provider: "xAI API")
        let text = try HTTPRequests.joinedText(request.parts, provider: "The xAI API")
        var messages: [JSONValue] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": .string(request.system)]) }
        messages.append(["role": "user", "content": .string(text)])
        var body: [String: JSONValue] = ["model": .string(model), "stream": true, "messages": .array(messages)]
        if let maxTokens = HTTPRequests.maxOutputTokens(request, settings: settings) { body["max_tokens"] = .int(maxTokens) }
        return try HTTPRequests.post(Endpoint.resolve(Self.completionsURL, override: settings.baseURL), body: .object(body),
                                     extraBodyJSON: settings.extraBodyJSON,
                                     headers: [("Authorization", "Bearer \(secret ?? "")"), ("Content-Type", "application/json")])
    }

    // ---- stream ----

    func parse(line: String, state: inout StreamState) throws -> [LLMEvent] {
        let chunk: JSONValue
        switch SSE.classify(line) {
        case .ignored: return []
        case .done: return [state.finished()]                  // the terminal event of this stream
        case .event(let value): chunk = value
        }
        if let error = chunk["error"] {
            let vendor = VendorError(json: ["error": error])
            throw LLMError.server(status: 500, message: vendor.text(status: nil))
        }
        if let usage = chunk["usage"] {                         // on every chunk; the last one counts
            if let input = usage["prompt_tokens"]?.intValue { state.inputTokens = input }
            if let output = usage["completion_tokens"]?.intValue { state.outputTokens = output }
        }
        let named = state.model(chunk["model"]?.stringValue)                  // every chunk names it; sent once (step 5c)
        let choice = chunk["choices"]?[0]
        if let reason = choice?["finish_reason"]?.stringValue { state.stopReason = Self.stopReason(reason) }
        // reasoning_content is ignored
        guard let content = choice?["delta"]?["content"]?.stringValue, !content.isEmpty else { return named }
        return named + [.textDelta(content)]
    }

    static func stopReason(_ reason: String) -> StopReason {
        switch reason {
        case "stop": return .endOfTurn
        case "length": return .maxTokens
        case "content_filter": return .refusal
        default: return .other
        }
    }

    // ---- errors: by status (section 5.4.3) ----

    func mapFailure(_ failure: HTTPFailure) -> LLMError {
        let text = failure.vendorError.text(status: failure.status)
        switch failure.status {
        case 401, 403: return .auth(text)
        case 429: return .rateLimited(retryAfter: failure.retryAfter(), message: text)
        case 404: return .modelNotFound(text)
        case 400, 415, 422:
            let lower = text.lowercased()
            return ["context", "token", "too long"].contains { lower.contains($0) } ? .contextTooLong(text) : .invalidRequest(text)
        case 500..<600: return .server(status: failure.status, message: text)
        default: return .invalidRequest(text)
        }
    }

    // ---- models ----

    func listModels(client: HTTPStreamClient, settings: ProviderSettings, secret: String?, showAll: Bool) async throws -> [ModelInfo] {
        let url = try Endpoint.resolve(Self.modelsURL, override: settings.baseURL)
        let data = try await client.json(for: HTTPRequests.get(url, headers: [("Authorization", "Bearer \(secret ?? "")")]))
        let json = try ModelLists.decode(data)
        return (json["data"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            return ModelInfo(id: id, displayName: id, contextWindow: item["context_length"]?.intValue)
        }
    }
}
