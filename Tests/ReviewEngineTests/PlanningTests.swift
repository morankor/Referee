import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// Planning (plan.md section 6.4): row "planning" of WP6, through the public `plan(paper:context:)`.
@Suite struct PlanningTests {
    /// The roster of section 5.2, as far as planning reads it.
    static func descriptor(_ id: ProviderID, maxPromptBytes: Int? = nil) -> ProviderDescriptor {
        let (auth, local, destination, pdf): (AuthMode, Bool, String, Bool) = switch id {
        case "anthropic-api": (.apiKey, false, "api.anthropic.com", true)
        case "openai-api": (.apiKey, false, "api.openai.com", true)
        case "gemini-api": (.apiKey, false, "generativelanguage.googleapis.com", true)
        case "xai-api": (.apiKey, false, "api.x.ai", false)
        case "ollama": (.local, true, "127.0.0.1:11434", false)
        case "claude-cli": (.subscriptionCLI, false, "claude", false)
        case "codex-cli": (.subscriptionCLI, false, "codex", false)
        default: (.none, true, "this Mac", false)
        }
        return ProviderDescriptor(id: id, displayName: id, vendor: "Test", authMode: auth, isLocal: local, destination: destination, supportsNativePDF: pdf,
                                  streaming: .token, maxPromptBytes: maxPromptBytes, retentionNote: "", isExperimental: false)
    }

    struct Row: CustomTestStringConvertible, Sendable {
        var name: String
        var provider: ProviderID
        var maxPromptBytes: Int? = nil
        var model: ModelInfo?
        var pages: Int
        var charactersPerPage: Int
        var fileBytes = 2_000_000
        var inputMode: InputMode = .auto
        var contextOverride: Int? = nil
        var encrypted = false
        var hasTextLayer = true
        var memory: UInt64 = 16 << 30
        // Expected:
        var sendsPDF: Bool
        var requests: Int?                  // nil: more than two (parts + 1)
        var tokens: Int? = nil
        var warning: String? = nil          // a fragment one of the warnings contains
        var noWarnings = false
        var blocking: String? = nil
        var testDescription: String { name }
    }

    static let claude200k = ModelInfo(id: "example-small", displayName: "Example Small", contextWindow: 200_000, supportsPDFInput: true)
    static let claude1m = ModelInfo(id: "example-large", displayName: "Example Large", contextWindow: 1_000_000, supportsPDFInput: true)
    static let gemma = ModelInfo(id: "gemma4:e4b", displayName: "gemma4:e4b", contextWindow: 131_072, supportsPDFInput: false)

    static let rows: [Row] = [
        Row(name: "Anthropic, a 200,000 window and 34 pages: the PDF in one request", provider: "anthropic-api", model: claude200k, pages: 34,
            charactersPerPage: 2_000, sendsPDF: true, requests: 1, tokens: 153_000, noWarnings: true),
        Row(name: "the same with no model: text, because 153,000 > the 128,000 assumed", provider: "anthropic-api", model: nil, pages: 34,
            charactersPerPage: 2_000, sendsPDF: false, requests: 1, warning: "128,000 tokens were assumed"),
        Row(name: "the same with the text input mode: text, nothing to warn about", provider: "anthropic-api", model: claude200k, pages: 34,
            charactersPerPage: 2_000, inputMode: .text, sendsPDF: false, requests: 1, noWarnings: true),
        Row(name: "an encrypted PDF: text, and the plan says the file is protected", provider: "anthropic-api", model: claude200k, pages: 34, charactersPerPage: 2_000,
            encrypted: true, sendsPDF: false, requests: 1, warning: "This PDF is protected, so its text is sent instead of the file."),
        Row(name: "a file over 30 MB: text", provider: "anthropic-api", model: claude200k, pages: 4, charactersPerPage: 2_000, fileBytes: 31_000_000,
            sendsPDF: false, requests: 1, warning: "larger than 30 MB"),
        Row(name: "150 pages: over Anthropic's 100 below a million tokens", provider: "anthropic-api", model: claude200k, pages: 150, charactersPerPage: 500,
            sendsPDF: false, requests: 1, warning: "more than the 100"),
        Row(name: "150 pages with a million-token window: within 600", provider: "anthropic-api", model: claude1m, pages: 150, charactersPerPage: 500,
            sendsPDF: true, requests: 1, tokens: 675_000),
        Row(name: "Gemini counts 1,500 tokens a page", provider: "gemini-api", model: ModelInfo(id: "g", displayName: "g", contextWindow: 1_000_000),
            pages: 34, charactersPerPage: 2_000, sendsPDF: true, requests: 1, tokens: 51_000),
        Row(name: "a model that refuses PDF input", provider: "anthropic-api",
            model: ModelInfo(id: "m", displayName: "m", contextWindow: 200_000, supportsPDFInput: false), pages: 4, charactersPerPage: 2_000,
            sendsPDF: false, requests: 1, warning: "does not accept PDF files"),
        Row(name: "Ollama, 24 GiB, a 131,072 model: context 32,768; 80,000 characters in one request", provider: "ollama", model: gemma, pages: 20,
            charactersPerPage: 3_980, memory: 24 << 30, sendsPDF: false, requests: 1, noWarnings: true),
        Row(name: "Ollama, 16 GiB: context 16,384; the same paper in parts plus the whole-paper pass", provider: "ollama", model: gemma, pages: 20,
            charactersPerPage: 3_980, memory: 16 << 30, sendsPDF: false, requests: nil, warning: "Ollama is given a context of 16,384 tokens"),
        Row(name: "Ollama, 16 GiB, with a context override of 65,536: the override wins over the cap and the model", provider: "ollama", model: gemma,
            pages: 20, charactersPerPage: 3_980, contextOverride: 65_536, memory: 16 << 30, sendsPDF: false, requests: 1, noWarnings: true),
        Row(name: "an override wins over the model's window elsewhere too", provider: "anthropic-api", model: claude200k, pages: 34, charactersPerPage: 2_000,
            contextOverride: 100_000, sendsPDF: false, requests: 1, warning: "does not fit"),
        Row(name: "a CLI without PDF delivery: text, and nothing to say in automatic mode", provider: "claude-cli", model: nil, pages: 34, charactersPerPage: 2_000,
            sendsPDF: false, requests: 1, noWarnings: true),
        Row(name: "a CLI without PDF delivery, PDF mode asked for: text, and the plan says why", provider: "claude-cli", model: nil, pages: 4, charactersPerPage: 2_000,
            inputMode: .pdf, sendsPDF: false, requests: 1, warning: "does not accept PDF files"),
        Row(name: "a CLI whose prompt is limited in bytes reads a long paper in parts", provider: "codex-cli", maxPromptBytes: 60_000, model: nil, pages: 20,
            charactersPerPage: 3_980, sendsPDF: false, requests: nil, warning: "Paper will be read in"),
        Row(name: "a context of 2,048 tokens blocks", provider: "xai-api", model: ModelInfo(id: "tiny", displayName: "tiny", contextWindow: 2_048),
            pages: 4, charactersPerPage: 2_000, sendsPDF: false, requests: 0, blocking: "This model's context window is too small."),
        Row(name: "Ollama with a context of 2,048 blocks too", provider: "ollama", model: nil, pages: 4, charactersPerPage: 2_000, contextOverride: 2_048,
            sendsPDF: false, requests: 0, blocking: "This model's context window is too small."),
        Row(name: "a scanned PDF and a text-only provider block", provider: "xai-api", model: ModelInfo(id: "x", displayName: "x", contextWindow: 256_000),
            pages: 1, charactersPerPage: 0, hasTextLayer: false, sendsPDF: false, requests: 0,
            blocking: "This PDF has no text layer; choose a provider that accepts PDF files."),
        Row(name: "a scanned PDF goes as a PDF where it can", provider: "anthropic-api", model: claude200k, pages: 1, charactersPerPage: 0,
            hasTextLayer: false, sendsPDF: true, requests: 1, tokens: 4_500),
    ]

    @Test(arguments: rows)
    func planning(_ row: Row) async {
        let paper = EngineTest.paper(pageCount: row.pages, charactersPerPage: row.charactersPerPage, fileBytes: row.fileBytes, encrypted: row.encrypted,
                                     hasTextLayer: row.hasTextLayer)
        let provider = StaticProvider(descriptor: Self.descriptor(row.provider, maxPromptBytes: row.maxPromptBytes), availability: .ready(detail: ""),
                                      models: row.model.map { [$0] } ?? [])
        let engine = EngineTest.engine([provider], paper: paper, memory: row.memory)
        let settings = ProviderSettings(enabled: true, contextWindowOverride: row.contextOverride, inputMode: row.inputMode)
        let plan = await engine.plan(paper: paper, context: EngineTest.context(provider: row.provider, model: row.model, settings: settings))

        #expect(plan.sendsPDF == row.sendsPDF)
        if let requests = row.requests {
            #expect(plan.requestCount == requests)
        } else {
            #expect(plan.requestCount > 2)
        }
        if let tokens = row.tokens { #expect(plan.estimatedInputTokens == tokens) }
        if let warning = row.warning { #expect(plan.warnings.contains { $0.contains(warning) }, "warnings: \(plan.warnings)") }
        if row.noWarnings { #expect(plan.warnings.isEmpty, "warnings: \(plan.warnings)") }
        #expect(plan.blockingReason == row.blocking)
        #expect(plan.destination == Self.descriptor(row.provider).destination)
        #expect(plan.isLocal == Self.descriptor(row.provider).isLocal)
    }

    /// The contexts behind the Ollama rows, and what every Ollama request carries.
    @Test func ollamaContextsAndReserves() {
        let ollama = Self.descriptor("ollama")
        func budget(_ memory: UInt64, model: ModelInfo? = Self.gemma, override: Int? = nil) -> TokenBudget {
            TokenBudget(descriptor: ollama, settings: ProviderSettings(enabled: true, contextWindowOverride: override, inputMode: .auto), model: model,
                        job: .review, physicalMemoryBytes: memory)
        }
        #expect(budget(24 << 30).context == 32_768)
        #expect(budget(24 << 30).reserve == 4_096)
        #expect(budget(24 << 30).inputBudget == 24_648)          // "about 86,000 characters" (section 6.4)
        #expect(budget(16 << 30).context == 16_384)
        #expect(budget(16 << 30).inputBudget == 8_264)
        #expect(budget(16 << 30, override: 65_536).context == 65_536)
        #expect(budget(64 << 30, model: ModelInfo(id: "s", displayName: "s", contextWindow: 8_192)).context == 8_192)
        #expect(budget(16 << 30, override: 2_048).reserve == 512)
        let limits = budget(24 << 30).requestLimits(settings: ProviderSettings(enabled: true, maxOutputTokens: 99, inputMode: .auto))
        #expect(limits.contextWindow == 32_768)
        #expect(limits.maxOutputTokens == 4_096)
        // Elsewhere the provider's own default context and the settings' maximum.
        let anthropic = TokenBudget(descriptor: Self.descriptor("anthropic-api"), settings: ProviderSettings(enabled: true, maxOutputTokens: 99, inputMode: .auto),
                                    model: nil, job: .review, physicalMemoryBytes: 16 << 30)
        #expect(anthropic.inputBudget == 128_000 - 16_000 - 3_000 - 1_024)
        let anthropicLimits = anthropic.requestLimits(settings: ProviderSettings(enabled: true, maxOutputTokens: 99, inputMode: .auto))
        #expect(anthropicLimits.contextWindow == nil)
        #expect(anthropicLimits.maxOutputTokens == 99)
        let cli = TokenBudget(descriptor: Self.descriptor("claude-cli"), settings: ProviderSettings(enabled: true, inputMode: .auto), model: nil,
                              job: .reply, physicalMemoryBytes: 16 << 30)
        #expect(cli.inputBudget == 200_000 - 4_000 - 3_000 - 1_024 - 30_000)
    }

    /// The Ollama request of a review sets the context and the reserve.
    @Test func anOllamaReviewRequestCarriesContextAndReserve() async throws {
        let mock = MockLLMProvider(id: "ollama")
        let paper = try makeSamplePaper()
        let engine = EngineTest.engine([mock], paper: paper, memory: 24 << 30)
        _ = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: EngineTest.context(provider: "ollama", model: Self.gemma)))
        #expect(mock.recordedRequests.count == 1)
        #expect(mock.recordedRequests.first?.contextWindow == 32_768)
        #expect(mock.recordedRequests.first?.maxOutputTokens == 4_096)
        #expect(mock.recordedRequests.first?.model == "gemma4:e4b")
    }

    @Test func anUnknownProviderCannotPlan() async throws {
        let paper = try makeSamplePaper()
        let plan = await EngineTest.engine([], paper: paper).plan(paper: paper, context: EngineTest.context(provider: "nowhere"))
        #expect(plan.blockingReason != nil)
        #expect(plan.destination == "")
        #expect(plan.requestCount == 0)
    }

    @Test func theSamplePaperFitsTheMockInOnePass() async throws {
        let paper = try makeSamplePaper()
        let plan = await EngineTest.engine([MockLLMProvider()], paper: paper).plan(paper: paper, context: EngineTest.context())
        #expect(plan == SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: Planning.tokens(forCharacters: FakePaperRenderer().render(paper.text, pages: nil).count),
                                 destination: "this Mac", isLocal: true))
    }
}
