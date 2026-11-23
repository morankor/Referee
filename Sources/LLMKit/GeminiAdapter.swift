import Foundation
import RefereeCore

/// Gemini Interactions API (plan section 5.4.4).
struct GeminiAdapter: HTTPProviderAdapter {
    let id: ProviderID = "gemini-api"

    static let interactionsURL = "https://generativelanguage.googleapis.com/v1/interactions"
    static let betaInteractionsURL = "https://generativelanguage.googleapis.com/v1beta/interactions"
    static let modelsURL = "https://generativelanguage.googleapis.com/v1/models"
    /// Model names containing any of these are hidden unless "Show all" is on.
    static let hiddenModelWords = ["embedding", "tts", "image", "live", "transcribe", "omni", "banana", "robotics", "veo", "lyria"]

    /// Whether `/v1/interactions` answered "not found" once, so that this provider uses `/v1beta` from then on. Copies of
    /// the adapter share it; it lasts as long as the app runs.
    let betaPath = BetaPathMemory()

    func descriptor(settings: ProviderSettings) -> ProviderDescriptor {
        ProviderDescriptor(id: id, displayName: "Gemini API", vendor: "Google", authMode: .apiKey, isLocal: false,
                           destination: Endpoint.destination(Self.interactionsURL, override: settings.baseURL), supportsNativePDF: true,
                           streaming: .token, retentionNote: "Sent with store=false.", isExperimental: false)
    }

    // ---- request ----

    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest {
        let model = try HTTPRequests.model(for: request, settings: settings, provider: "Gemini API")
        var input: [JSONValue] = []
        for part in request.parts {
            switch part {
            case .text(let text):
                if !text.isEmpty { input.append(["type": "text", "text": .string(text)]) }
            case .pdf(let data, _):
                input.append(["type": "document", "data": .string(HTTPRequests.base64(data)), "mime_type": "application/pdf"])
            case .cacheBoundary:
                continue
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": true,
            "store": false,                                     // stored for 55 days (paid) or 1 day (free) otherwise
            "input": .array(input),
        ]
        if !request.system.isEmpty { body["system_instruction"] = .string(request.system) }
        if let maxTokens = HTTPRequests.maxOutputTokens(request, settings: settings) {
            body["generation_config"] = ["max_output_tokens": .int(maxTokens)]
        }
        let endpoint = betaPath.isOn ? Self.betaInteractionsURL : Self.interactionsURL
        return try HTTPRequests.post(Endpoint.resolve(endpoint, override: settings.baseURL), body: .object(body),
                                     extraBodyJSON: settings.extraBodyJSON,
                                     headers: [("x-goog-api-key", secret ?? ""), ("Content-Type", "application/json")])
    }

    /// [A] of section 5.4.4: a 404 whose code is `not_found` (not `model_not_found`) on `/v1/interactions` is tried once
    /// more on `/v1beta/interactions`, and the provider stays there.
    func fallbackRequest(after failure: HTTPFailure, for request: URLRequest) -> URLRequest? {
        guard failure.status == 404, failure.vendorError.code == "not_found",
              let url = request.url, url.path == "/v1/interactions",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/v1beta/interactions"
        guard let betaURL = components.url else { return nil }
        betaPath.turnOn()
        var retry = request
        retry.url = betaURL
        return retry
    }

    // ---- stream ----

    func parse(line: String, state: inout StreamState) throws -> [LLMEvent] {
        let json: JSONValue
        switch SSE.classify(line) {
        case .ignored: return []
        case .done: return try finish(state: state)           // after `event: done`; the stream has ended by then
        case .event(let value): json = value
        }
        switch json["event_type"]?.stringValue {
        case "interaction.created":
            return state.model(Self.modelName(in: json))                      // the interaction names its model (step 5c)
        case "step.delta":
            guard json["delta"]?["type"]?.stringValue == "text",
                  let text = json["delta"]?["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.textDelta(text)]                           // thought_signature, thought_summary, … are ignored
        case "interaction.completed":
            let interaction = json["interaction"]
            if let input = interaction?["usage"]?["total_input_tokens"]?.intValue { state.inputTokens = input }
            if let output = interaction?["usage"]?["total_output_tokens"]?.intValue { state.outputTokens = output }
            let named = state.model(Self.modelName(in: json))
            switch interaction?["status"]?.stringValue {
            case "completed": return named + [state.finished(.endOfTurn)]
            case "incomplete": return named + [state.finished(.maxTokens)]      // "hitting max_tokens"
            case "failed": throw LLMError.server(status: 500, message: "the interaction failed")
            default: return named + [state.finished(.other)]
            }
        case "error":
            let vendor = VendorError(json: json)
            throw Self.codeError(code: vendor.code, message: vendor.message, status: nil, retryAfter: nil)
        default:
            return []                                           // unknown events are ignored, as the docs ask
        }
    }

    /// The model an interaction event names (step 5c): a `modelVersion` (the field of generateContent responses) when an
    /// event carries one, else the interaction's `model` (Appendix D.3: `interaction.created` has it).
    static func modelName(in json: JSONValue) -> String? {
        json["modelVersion"]?.stringValue ?? json["interaction"]?["modelVersion"]?.stringValue ?? json["interaction"]?["model"]?.stringValue
    }

    // ---- errors (section 5.5) ----

    func mapFailure(_ failure: HTTPFailure) -> LLMError {
        let vendor = failure.vendorError
        return Self.codeError(code: vendor.code, message: vendor.message, status: failure.status, retryAfter: failure.retryAfter())
    }

    /// By the error's code; any code not in the table is a server fault. Without a code, by the HTTP status.
    static func codeError(code: String?, message: String?, status: Int?, retryAfter: Double?) -> LLMError {
        let text = message ?? code ?? status.map { "HTTP \($0)" } ?? "unknown error"
        guard let code = code?.lowercased() else {
            switch status {
            case 401, 403: return .auth(text)
            case 404: return .modelNotFound(text)
            case 429: return .rateLimited(retryAfter: retryAfter, message: text)
            case 503: return .overloaded(retryAfter: retryAfter)
            case let status? where (400..<500).contains(status): return .invalidRequest(text)
            default: return .server(status: status ?? 500, message: text)
            }
        }
        switch code {
        case "authentication", "permission_denied":
            return .auth(text)
        case "rate_limit_exceeded", "too_many_requests":
            return .rateLimited(retryAfter: retryAfter, message: text)
        case "payment_required", "quota_exceeded":
            return .quotaExhausted(text)
        case "service_unavailable":
            return .overloaded(retryAfter: retryAfter)
        case "model_not_found":
            return .modelNotFound(text)
        case "invalid_request":
            return text.lowercased().contains("token") ? .contextTooLong(text) : .invalidRequest(text)
        case "parameter_unknown", "failed_precondition":
            return .invalidRequest(text)
        case "safety", "recitation", "prohibited_content", "blocklist", "spii", "content_blocked", "language":
            return .refused(text)
        default:
            return .server(status: status ?? 500, message: text)   // api_error, deadline_exceeded, aborted, gateway_timeout, …
        }
    }

    // ---- models ----

    func listModels(client: HTTPStreamClient, settings: ProviderSettings, secret: String?, showAll: Bool) async throws -> [ModelInfo] {
        let base = try Endpoint.resolve(Self.modelsURL, override: settings.baseURL)
        let headers = [("x-goog-api-key", secret ?? "")]
        let models = try await ModelLists.paginate { pageToken in
            var query = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await client.json(for: HTTPRequests.get(Endpoint.adding(query, to: base), headers: headers))
            let json = try ModelLists.decode(data)
            let page = (json["models"]?.arrayValue ?? []).compactMap { item -> ModelInfo? in
                guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                guard !id.isEmpty else { return nil }
                return ModelInfo(id: id, displayName: item["displayName"]?.stringValue ?? id,
                                 contextWindow: item["inputTokenLimit"]?.intValue, maxOutputTokens: item["outputTokenLimit"]?.intValue)
            }
            return (page, json["nextPageToken"]?.stringValue)
        }
        return ModelLists.hiding(models, idsContaining: Self.hiddenModelWords, showAll: showAll)
    }
}

/// A flag that, once on, stays on. Lock-protected: providers are used from any task.
final class BetaPathMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isOn: Bool { lock.withLock { on } }

    func turnOn() { lock.withLock { on = true } }
}
