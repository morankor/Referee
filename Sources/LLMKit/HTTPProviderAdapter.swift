import Foundation
import RefereeCore

/// One small type per vendor (plan section 5.3): how a request is written, how the body is read, how a failure maps to
/// an `LLMError`, and how models are listed. `HTTPProvider` does the rest: secrets, settings, streaming and retry.
///
/// The four functions of section 5.3 are the core; the others have defaults below and are overridden where a vendor
/// differs (Ollama needs no key and has its own availability; Gemini may move to `/v1beta`).
protocol HTTPProviderAdapter: Sendable {
    /// The provider id, which is also the key's name in the Keychain item (section 5.8).
    var id: ProviderID { get }
    /// Whether requests carry an API key. False only for Ollama.
    var needsKey: Bool { get }
    /// The descriptor for the settings in force: the destination follows the base URL, and so does Ollama's locality.
    func descriptor(settings: ProviderSettings) -> ProviderDescriptor

    /// The streaming request. Throws `LLMError` for a request that cannot be sent (no model, a PDF part where none is
    /// accepted, a base URL that is not an address).
    func makeRequest(_ request: LLMRequest, settings: ProviderSettings, secret: String?) throws -> URLRequest
    func initialState(for request: LLMRequest, settings: ProviderSettings) -> StreamState
    /// One line of the body. May throw `LLMError` for an in-stream error.
    func parse(line: String, state: inout StreamState) throws -> [LLMEvent]
    func mapFailure(_ failure: HTTPFailure) -> LLMError
    /// Called at the end of the body, which a vendor's terminal event has not ended.
    func finish(state: StreamState) throws -> [LLMEvent]

    func mapTransport(_ error: URLError) -> LLMError
    /// A second request to make once, instead of failing (Gemini's `/v1beta` fallback, section 5.4.4). nil = fail.
    func fallbackRequest(after failure: HTTPFailure, for request: URLRequest) -> URLRequest?

    /// The model list. `showAll` turns off the filters of section 5.4.
    func listModels(client: HTTPStreamClient, settings: ProviderSettings, secret: String?, showAll: Bool) async throws -> [ModelInfo]
    /// Cheap, no tokens spent. `secret` reads the stored key.
    func availability(client: HTTPStreamClient, settings: ProviderSettings, secret: () throws -> String?) async -> ProviderAvailability
}

extension HTTPProviderAdapter {
    var needsKey: Bool { true }

    func initialState(for request: LLMRequest, settings: ProviderSettings) -> StreamState { StreamState() }

    /// End of body: `.malformedResponse` unless the terminal event was seen (section 5.3).
    func finish(state: StreamState) throws -> [LLMEvent] {
        guard state.terminated else { throw LLMError.malformedResponse("stream ended early") }
        return []
    }

    func mapTransport(_ error: URLError) -> LLMError { HTTPStreamClient.defaultTransport(error) }

    func fallbackRequest(after failure: HTTPFailure, for request: URLRequest) -> URLRequest? { nil }

    /// API-key providers: ready when a key is stored. Nothing is sent.
    func availability(client: HTTPStreamClient, settings: ProviderSettings, secret: () throws -> String?) async -> ProviderAvailability {
        let name = descriptor(settings: settings).displayName
        if let problem = Endpoint.problem(settings.baseURL) { return .unavailable(reason: problem) }
        do {
            guard let key = try secret()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return .needsSetup(reason: "No API key", hint: "Add your \(name) key in Settings ▸ Providers.")
            }
            return .ready(detail: "Key set")
        } catch {
            return .needsSetup(reason: "The saved key could not be read from the Keychain",
                               hint: "Allow access when macOS asks for it, then try again.")
        }
    }
}

extension Endpoint {
    /// Why the base URL setting cannot be used, or nil when it can (or is not set).
    static func problem(_ override: String?) -> String? {
        do {
            _ = try resolve("https://example.invalid/", override: override)
            return nil
        } catch {
            return "The base URL in Settings is not an http or https address."
        }
    }
}
