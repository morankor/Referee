import Foundation

public enum AuthMode: String, Codable, Sendable { case apiKey, subscriptionCLI, local, none }

public struct ProviderRef: Codable, Sendable, Hashable {
    public var providerID: ProviderID
    public var model: String?                // nil = the provider's own default (CLI providers)
    public init(providerID: ProviderID, model: String?) { self.providerID = providerID; self.model = model }
}

public enum StreamingGranularity: String, Codable, Sendable { case token, message }

public struct ProviderDescriptor: Codable, Sendable, Equatable {
    public var id: ProviderID
    public var displayName: String           // "Anthropic API", "Claude Code (subscription)"
    public var vendor: String                // "Anthropic", "OpenAI", "Google", "xAI", "Ollama", "Mock"
    public var authMode: AuthMode
    public var isLocal: Bool                 // true only if manuscript text never leaves this machine
    public var destination: String           // shown in the confidentiality indicator: host name or CLI name
    public var supportsNativePDF: Bool       // provider-level; ModelInfo.supportsPDFInput can still veto
    public var pdfDeliveryNote: String?      // how a CLI provider hands the file over, e.g. "sent as page images"; nil for HTTP providers
    public var streaming: StreamingGranularity
    public var maxPromptBytes: Int?          // transport limit (stdin/argv); nil = none
    public var retentionNote: String         // one line for the privacy popover
    public var isExperimental: Bool
    public init(id: ProviderID, displayName: String, vendor: String, authMode: AuthMode, isLocal: Bool, destination: String, supportsNativePDF: Bool,
                pdfDeliveryNote: String? = nil, streaming: StreamingGranularity, maxPromptBytes: Int? = nil, retentionNote: String, isExperimental: Bool) {
        self.id = id; self.displayName = displayName; self.vendor = vendor; self.authMode = authMode; self.isLocal = isLocal; self.destination = destination
        self.supportsNativePDF = supportsNativePDF; self.pdfDeliveryNote = pdfDeliveryNote; self.streaming = streaming; self.maxPromptBytes = maxPromptBytes
        self.retentionNote = retentionNote; self.isExperimental = isExperimental
    }
}

public enum ProviderAvailability: Sendable, Equatable {
    case ready(detail: String)                       // "Key set", "Logged in", "Ollama 0.40.17"
    case needsSetup(reason: String, hint: String)    // no key / not installed / not logged in
    case unavailable(reason: String)                 // binary blocked, server not running
}

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int?           // input tokens; nil = unknown
    public var maxOutputTokens: Int?
    public var supportsPDFInput: Bool?       // nil = unknown
    public init(id: String, displayName: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, supportsPDFInput: Bool? = nil) {
        self.id = id; self.displayName = displayName; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
        self.supportsPDFInput = supportsPDFInput
    }
}

public enum LLMPart: Sendable, Equatable {
    case text(String)
    case pdf(data: Data, fileName: String)
    case cacheBoundary                       // parts before this marker are identical across requests (prompt-cache hint)
}

public enum RequestPurpose: String, Codable, Sendable { case review, discussion, question, report, revise, ping }

/// One system prompt + one user turn -> streamed text. There is deliberately no multi-turn API (see plan section 5.1).
public struct LLMRequest: Sendable, Equatable {
    public var model: String?
    public var system: String
    public var parts: [LLMPart]
    public var maxOutputTokens: Int?         // nil = provider default (the Anthropic adapter substitutes min(model max, 32_000))
    public var contextWindow: Int?           // tokens to allocate (Ollama num_ctx); nil = provider default
    public var purpose: RequestPurpose
    public init(model: String? = nil, system: String, parts: [LLMPart] = [], maxOutputTokens: Int? = nil, contextWindow: Int? = nil, purpose: RequestPurpose) {
        self.model = model; self.system = system; self.parts = parts; self.maxOutputTokens = maxOutputTokens; self.contextWindow = contextWindow
        self.purpose = purpose
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public enum StopReason: String, Codable, Sendable { case endOfTurn, maxTokens, refusal, other }

public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case status(String)                      // human-readable progress, never model text
    /// The model that answers, as the provider's own stream names it (Anthropic's message_start, the OpenAI response
    /// object, Gemini's interaction, every xAI and Ollama chunk, Claude Code's init line; step 5c). Before `.finished`,
    /// whenever the stream names a model other than the one it last named, so usually once; the last one counts. A
    /// provider whose stream names none (Codex, Antigravity, Grok Build, the mocks) never sends it.
    case model(String)
    case finished(StopReason, Usage?)        // exactly once, last, on success
}

public enum LLMError: RefereeError, Equatable {
    case notConfigured(String)
    case auth(String)
    case rateLimited(retryAfter: Double?, message: String)
    case quotaExhausted(String)
    case overloaded(retryAfter: Double?)
    case contextTooLong(String)
    case invalidRequest(String)
    case modelNotFound(String)
    case refused(String)
    case network(String)
    case server(status: Int, message: String)
    case cliLaunchFailed(String)
    case cliTimeout(phase: String)
    case cliExited(code: Int32, stderrTail: String)
    case toolUseBlocked(String)              // a CLI exposed or tried to use a tool the invocation does not allow; the run was killed
    case malformedResponse(String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .server: return true
        default: return false
        }
    }
    public var userMessage: String {
        switch self {
        case .notConfigured(let m): return "Provider is not set up: \(m)"
        case .auth(let m): return "Authentication failed: \(m)"
        case .rateLimited(_, let m): return "Rate limited: \(m)"
        case .quotaExhausted(let m): return "Usage limit reached: \(m)"
        case .overloaded: return "The provider is overloaded."
        case .contextTooLong(let m): return "The input is too long for this model: \(m)"
        case .invalidRequest(let m): return "The provider rejected the request: \(m)"
        case .modelNotFound(let m): return "Model not found: \(m)"
        case .refused(let m): return "The model declined to answer: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .server(let s, let m): return "Provider error \(s): \(m)"
        case .cliLaunchFailed(let m): return "Could not start the command-line tool: \(m)"
        case .cliTimeout(let p): return "The command-line tool timed out (\(p))."
        case .cliExited(let c, let t): return "The command-line tool exited with code \(c): \(t)"
        case .toolUseBlocked(let t): return "The command-line tool tried to use a tool (\(t)); the run was stopped and nothing it produced after that point was used."
        case .malformedResponse(let m): return "Unexpected response from the provider: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
    public var recoverySuggestion: String? { nil }
}

public protocol LLMProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    /// Cheap, no model tokens spent. For CLI providers: resolve binary, run `--version` (20 s cap) and the auth-status command.
    func availability() async -> ProviderAvailability
    func listModels() async throws -> [ModelInfo]
    /// includeHidden: true = the whole list, without the filters of sections 5.4.2 and 5.4.4 (Settings' "Show all").
    /// Default: listModels(), for providers that filter nothing.
    func listModels(includeHidden: Bool) async throws -> [ModelInfo]
    /// Cold stream: work starts when iterated; cancelling the consuming Task cancels the HTTP request / kills the process.
    /// Throws only LLMError.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

extension LLMProvider {
    public func listModels(includeHidden: Bool) async throws -> [ModelInfo] { try await listModels() }
}

public protocol ProviderResolving: Sendable {
    var all: [any LLMProvider] { get }
    func provider(id: ProviderID) -> (any LLMProvider)?
}

public protocol SecretStoring: Sendable {
    func secret(for key: String) throws -> String?
    /// nil deletes. All secrets live in one stored item, so this is read-modify-write: it MUST throw SecretError.unreadable
    /// unless the existing item was read successfully or is known not to exist. Treating a failed read as "empty" would
    /// overwrite every other stored key (plan section 5.8).
    func setSecret(_ value: String?, for key: String) throws
}

public enum SecretError: RefereeError, Equatable {
    case unreadable(status: Int32)           // the item exists but could not be read (the user denied access, or the keychain is locked)
    case writeFailed(status: Int32)
    public var userMessage: String {
        switch self {
        case .unreadable: return "The saved keys could not be read from the Keychain, so nothing was changed."
        case .writeFailed(let s): return "The Keychain rejected the change (status \(s))."
        }
    }
    public var recoverySuggestion: String? { "Allow access when macOS asks for it, then try again." }
    public var isRetryable: Bool { true }
}
