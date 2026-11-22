import Foundation
import RefereeCore

/// An HTTP provider: one vendor adapter, the app's environment and the retry rule (plan sections 5.3–5.7). Settings and
/// the key are read when a request is made, so edits apply without a restart.
struct HTTPProvider: LLMProvider {
    let adapter: any HTTPProviderAdapter
    let environment: ProviderEnvironment
    let retry: RetryPolicy

    var id: ProviderID { adapter.id }

    var descriptor: ProviderDescriptor { adapter.descriptor(settings: settings) }

    func availability() async -> ProviderAvailability {
        let secrets = environment.secrets
        let id = self.id
        return await adapter.availability(client: client, settings: settings, secret: { try secrets.secret(for: id) })
    }

    func listModels() async throws -> [ModelInfo] {
        try await listModels(includeHidden: false)
    }

    /// The model list; with `includeHidden`, also the models that the filters of section 5.4 hide (Settings' "Show all").
    func listModels(includeHidden: Bool) async throws -> [ModelInfo] {
        let settings = self.settings
        let key = try self.key()
        do {
            return try await adapter.listModels(client: client, settings: settings, secret: key, showAll: includeHidden)
        } catch {
            throw llmError(error).removing(secret: key)
        }
    }

    /// Cold: nothing happens until the stream is iterated. Cancelling the consuming task cancels the HTTP request.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let provider = self
        let reader = RetryingReader(policy: retry, providerID: id) { try provider.attempt(request) }
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    // ---- internal ----

    var settings: ProviderSettings { environment.settings(adapter.id) }

    var client: HTTPStreamClient {
        let adapter = self.adapter
        return HTTPStreamClient(session: environment.urlSession, transport: { adapter.mapTransport($0) })
    }

    /// One attempt of a stream: the request is built now, from the settings and the key as they are now.
    func attempt(_ request: LLMRequest) throws -> AsyncThrowingStream<LLMEvent, Error> {
        let settings = self.settings
        let key = try self.key()
        let urlRequest = try adapter.makeRequest(request, settings: settings, secret: key)
        let sendsPDF = request.parts.contains { part in
            if case .pdf = part { return true }
            return false
        }
        let reader = AttemptReader(adapter: adapter, client: client, request: urlRequest,
                                   state: adapter.initialState(for: request, settings: settings), key: key, sendsPDF: sendsPDF)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    /// The stored key, trimmed; nil for a provider that needs none. No key, or a key that cannot be read, is
    /// `.notConfigured`, thrown before any request is made (section 5.5).
    func key() throws -> String? {
        guard adapter.needsKey else { return nil }
        let stored: String?
        do {
            stored = try environment.secrets.secret(for: adapter.id)
        } catch {
            throw LLMError.notConfigured("the saved API key could not be read from the Keychain")
        }
        guard let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LLMError.notConfigured("no API key is stored for \(adapter.descriptor(settings: settings).displayName)")
        }
        return key
    }

    /// Any error of a list or availability call, as the `LLMError` the caller sees.
    func llmError(_ error: Error) -> LLMError {
        switch client.translate(error) {
        case let failure as HTTPFailure: return adapter.mapFailure(failure)
        case let timedOut as TimedOut: return timedOut.error
        case let llm as LLMError: return llm
        default: return .network(error.localizedDescription)
        }
    }
}

/// One attempt: sends the request and turns the body into events through the adapter. It stops at the first
/// `.finished`, so exactly one is ever yielded. Every `next()` runs in the consumer's task, one at a time, so the state
/// needs no lock.
final class AttemptReader: @unchecked Sendable {
    private let adapter: any HTTPProviderAdapter
    private let client: HTTPStreamClient
    private var request: URLRequest
    private var state: StreamState
    private let key: String?
    private let sendsPDF: Bool
    private var lines: AsyncThrowingStream<String, Error>.AsyncIterator?
    private var pending: [LLMEvent] = []
    private var done = false
    private var fellBack = false

    init(adapter: any HTTPProviderAdapter, client: HTTPStreamClient, request: URLRequest, state: StreamState, key: String?, sendsPDF: Bool) {
        self.adapter = adapter
        self.client = client
        self.request = request
        self.state = state
        self.key = key
        self.sendsPDF = sendsPDF
    }

    func next() async throws -> LLMEvent? {
        do {
            return try await produce()
        } catch {
            done = true
            pending.removeAll()
            switch client.translate(error) {
            case let llm as LLMError: throw llm.removing(secret: key)
            case let timedOut as TimedOut: throw TimedOut(error: timedOut.error.removing(secret: key))
            case let failure as HTTPFailure: throw adapter.mapFailure(failure).removing(secret: key)
            case let other: throw other
            }
        }
    }

    private func produce() async throws -> LLMEvent? {
        while true {
            if !pending.isEmpty {
                let event = pending.removeFirst()
                if case .finished = event {
                    done = true
                    pending.removeAll()
                }
                return event
            }
            if done { return nil }
            let line: String?
            do {
                line = try await nextLine()
            } catch let failure as HTTPFailure {
                if !fellBack, let alternate = adapter.fallbackRequest(after: failure, for: request) {
                    fellBack = true
                    request = alternate
                    lines = nil
                    continue
                }
                throw adapter.mapFailure(failure)
            }
            guard let line else {
                done = true
                // The line stream of a cancelled consumer ends without an error (AsyncThrowingStream(unfolding:) stops
                // calling its closure): a cancellation, not a body that ended early (Gate 1, seen under load).
                if Task.isCancelled { throw LLMError.cancelled }
                pending = try adapter.finish(state: state)
                continue
            }
            pending = try adapter.parse(line: line, state: &state)
        }
    }

    private func nextLine() async throws -> String? {
        var iterator: AsyncThrowingStream<String, Error>.AsyncIterator
        if let existing = lines {
            iterator = existing
        } else {
            Log.event("llm.request", ["provider": .id(adapter.id), "bytes": .int(request.httpBody?.count ?? 0), "pdf": .bool(sendsPDF)])
            iterator = client.lines(for: request).makeAsyncIterator()
        }
        defer { lines = iterator }
        return try await iterator.next()
    }
}
