import Foundation
import RefereeCore

/// Ollama (plan section 5.4.5): NDJSON chat, no key, local unless the base URL points elsewhere.
struct OllamaAdapter: HTTPProviderAdapter {
    let id: ProviderID = "ollama"
    var needsKey: Bool { false }

    static let chatURL = "http://127.0.0.1:11434/api/chat"
    static let tagsURL = "http://127.0.0.1:11434/api/tags"
    static let showURL = "http://127.0.0.1:11434/api/show"
    static let versionURL = "http://127.0.0.1:11434/api/version"
    /// `num_ctx` when neither the request nor the settings give one; Ollama's own smallest default (section 5.4.5).
    static let fallbackContextWindow = 4_096
    static let contextFullStatus = "context window full; input may have been truncated"

    func descriptor(settings: ProviderSettings) -> ProviderDescriptor {
        let local = Endpoint.isLoopback(Self.chatURL, override: settings.baseURL)
        let note = local ? "Processed on this Mac; nothing is sent."
                         : "Sent to \(Endpoint.host(Self.chatURL, override: settings.baseURL)) on your network."
        return ProviderDescriptor(id: id, displayName: "Ollama (local)", vendor: "Ollama", authMode: .local, isLocal: local,
                                  destination: Endpoint.destination(Self.chatURL, override: settings.baseURL), supportsNativePDF: false,
                                  streaming: .token, retentionNote: note, isExperimental: false)
    }

    // ---- request ----

    /// `"think": false` is not written here: it comes from the provider's default `extraBodyJSON` (section 5.4.5).
    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest {
        let model = try HTTPRequests.model(for: request, settings: settings, provider: "Ollama")
        let text = try HTTPRequests.joinedText(request.parts, provider: "Ollama")
        var options: [String: JSONValue] = ["num_ctx": .int(contextWindow(request, settings: settings)), "temperature": 0.2]
        if let maxTokens = HTTPRequests.maxOutputTokens(request, settings: settings) { options["num_predict"] = .int(maxTokens) }
        var messages: [JSONValue] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": .string(request.system)]) }
        messages.append(["role": "user", "content": .string(text)])
        let body: JSONValue = ["model": .string(model), "stream": true, "keep_alive": "10m", "options": .object(options),
                               "messages": .array(messages)]
        return try HTTPRequests.post(Endpoint.resolve(Self.chatURL, override: settings.baseURL), body: body,
                                     extraBodyJSON: settings.extraBodyJSON, headers: [("Content-Type", "application/json")])
    }

    /// `num_ctx` is set on every request: otherwise Ollama picks a context by available memory and silently truncates.
    func contextWindow(_ request: LLMRequest, settings: ProviderSettings) -> Int {
        request.contextWindow ?? settings.contextWindowOverride ?? Self.fallbackContextWindow
    }

    func initialState(for request: LLMRequest, settings: ProviderSettings) -> StreamState {
        StreamState(contextWindow: contextWindow(request, settings: settings))
    }

    // ---- stream ----

    func parse(line: String, state: inout StreamState) throws -> [LLMEvent] {
        guard let json = JSONValue.parse(line), json.objectValue != nil else { return [] }     // empty or not JSON
        if let error = json["error"] {
            throw LLMError.server(status: 500, message: VendorError(json: ["error": error]).text(status: nil))
        }
        var events: [LLMEvent] = []
        if let content = json["message"]?["content"]?.stringValue, !content.isEmpty {
            events.append(.textDelta(content))                 // message.thinking is ignored
        }
        guard json["done"]?.boolValue == true else { return events }
        switch json["done_reason"]?.stringValue {
        case "stop", nil: state.stopReason = .endOfTurn
        case "length": state.stopReason = .maxTokens
        default: state.stopReason = .other
        }
        state.inputTokens = json["prompt_eval_count"]?.intValue
        state.outputTokens = json["eval_count"]?.intValue
        if let window = state.contextWindow, (state.inputTokens ?? 0) + (state.outputTokens ?? 0) >= window - 16 {
            events.append(.status(Self.contextFullStatus))
        }
        events.append(state.finished())
        return events
    }

    // ---- errors (section 5.5) ----

    func mapFailure(_ failure: HTTPFailure) -> LLMError {
        let text = failure.vendorError.text(status: failure.status)
        switch failure.status {
        case 429: return .rateLimited(retryAfter: failure.retryAfter(), message: text)
        case 404: return .modelNotFound(text)
        case 400..<500: return .invalidRequest(text)
        default: return .server(status: failure.status, message: text)
        }
    }

    /// A refused connection means the server is not running (section 5.5).
    func mapTransport(_ error: URLError) -> LLMError {
        error.code == .cannotConnectToHost ? .notConfigured("Ollama is not running") : HTTPStreamClient.defaultTransport(error)
    }

    // ---- availability and models ----

    func availability(client: HTTPStreamClient, settings: ProviderSettings, secret: () throws -> String?) async -> ProviderAvailability {
        let url: URL
        do {
            url = try Endpoint.resolve(Self.versionURL, override: settings.baseURL)
        } catch {
            return .unavailable(reason: "The base URL in Settings is not an http or https address.")
        }
        do {
            let data = try await client.json(for: HTTPRequests.get(url, headers: [], timeout: 2))
            let version = JSONValue.parse(data)?["version"]?.stringValue
            return .ready(detail: version.map { "Ollama \($0)" } ?? "Ollama")
        } catch LLMError.notConfigured {
            return .needsSetup(reason: "Ollama is not running", hint: "Start the Ollama app or run `ollama serve`.")
        } catch {
            return .unavailable(reason: "Ollama at \(Endpoint.destination(Self.versionURL, override: settings.baseURL)) did not answer.")
        }
    }

    /// `/api/tags`; for a model whose entry lacks the context length (or the capabilities), `/api/show`. Models that
    /// cannot complete text (embedding models) are always hidden.
    func listModels(client: HTTPStreamClient, settings: ProviderSettings, secret: String?, showAll: Bool) async throws -> [ModelInfo] {
        let url = try Endpoint.resolve(Self.tagsURL, override: settings.baseURL)
        let tags = try ModelLists.decode(try await client.json(for: HTTPRequests.get(url, headers: [])))
        var models: [ModelInfo] = []
        for item in tags["models"]?.arrayValue ?? [] {
            guard let name = item["name"]?.stringValue ?? item["model"]?.stringValue, !name.isEmpty else { continue }
            var contextWindow = item["details"]?["context_length"]?.intValue
            var capabilities = item["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            if contextWindow == nil || capabilities == nil, let shown = try await show(name, client: client, settings: settings) {
                contextWindow = contextWindow ?? shown.contextWindow
                capabilities = capabilities ?? shown.capabilities
            }
            if let capabilities, !capabilities.contains("completion") { continue }
            models.append(ModelInfo(id: name, displayName: name, contextWindow: contextWindow))
        }
        return models
    }

    /// `POST /api/show`: `model_info["<general.architecture>.context_length"]` and the capabilities. nil when the call
    /// fails for any reason but cancellation: the model is then listed without them.
    private func show(_ name: String, client: HTTPStreamClient, settings: ProviderSettings) async throws
        -> (contextWindow: Int?, capabilities: [String]?)? {
        let request = try HTTPRequests.post(Endpoint.resolve(Self.showURL, override: settings.baseURL), body: ["model": .string(name)],
                                            extraBodyJSON: nil, headers: [("Content-Type", "application/json")],
                                            timeout: HTTPRequests.listTimeout)
        let data: Data
        do {
            data = try await client.json(for: request)
        } catch LLMError.cancelled {
            throw LLMError.cancelled
        } catch {
            return nil
        }
        guard let json = JSONValue.parse(data) else { return nil }
        let info = json["model_info"]
        let contextWindow = info?["general.architecture"]?.stringValue.flatMap { info?["\($0).context_length"]?.intValue }
        return (contextWindow, json["capabilities"]?.arrayValue?.compactMap(\.stringValue))
    }
}
