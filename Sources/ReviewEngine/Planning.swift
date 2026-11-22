import Foundation
import RefereeCore

/// The constants of plan.md section 6.4.
enum Planning {
    static let charsPerToken = 3.5                 // measured 4.3–4.5 on these prompts with local models; 3.5 leaves room for mathematics
    static let promptOverheadTokens = 3_000        // system prompt, rubric, format, task
    static let cliOverheadTokens = 30_000          // a coding CLI's own instructions
    static let safetyTokens = 1_024
    static let unknownContextWindow = 128_000
    static let cliContextWindow = 200_000
    static let pdfTokensPerPage: [ProviderID: Int] = ["anthropic-api": 4_500, "claude-cli": 4_500, "openai-api": 3_500, "gemini-api": 1_500, "codex-cli": 1_500]
    /// For a provider that accepts PDF files but has no entry above (the mock, a provider added later): the largest rate.
    static let defaultPDFTokensPerPage = 4_500
    static let notesBudgetChars = 2_400
    static let minimumInputBudget = 1_500
    /// "file ≤ 30 MB", in the decimal megabytes Finder shows.
    static let maxPDFBytes = 30_000_000
    /// Room left in a CLI's prompt for everything besides the paper.
    static let promptBytesMargin = 20_000
    /// Replies and the report carry the whole paper only when it takes at most this share of the input budget.
    static let paperContextShare = 0.6
    static let ollamaReserveCap = 4_096

    static func ollamaContextCap(physicalMemoryBytes: UInt64) -> Int {
        physicalMemoryBytes >= 24 * 1_024 * 1_024 * 1_024 ? 32_768 : 16_384     // Ollama's own default for this much memory
    }

    /// Pages a provider accepts in one PDF; nil = no limit known.
    static func pdfPageLimit(provider: ProviderID, context: Int) -> Int? {
        switch provider {
        case "anthropic-api": return context < 1_000_000 ? 100 : 600
        case "gemini-api": return 1_000
        case "claude-cli": return 100
        case "codex-cli": return 40
        default: return nil
        }
    }

    enum Job {
        case review, reply, report

        var outputReserve: Int {
            switch self {
            case .review: return 16_000
            case .reply: return 4_000
            case .report: return 8_000
            }
        }
    }

    static func tokens(forCharacters characters: Int) -> Int {
        Int((Double(characters) / charsPerToken).rounded(.up))
    }

    static let contextTooSmall = "This model's context window is too small."
    static let noTextLayer = "This PDF has no text layer; choose a provider that accepts PDF files."
}

/// The token arithmetic of section 6.4 for one provider, model and job.
struct TokenBudget: Equatable {
    var context: Int
    var reserve: Int
    var inputBudget: Int
    var isOllama: Bool
    var isCLI: Bool
    /// The context window came from an override or the model list, not from a fallback.
    var contextKnown: Bool
    /// The model's own window when Ollama's cap cut it.
    var cappedFrom: Int?

    /// `LLMRequest.contextWindow` and `maxOutputTokens`: for Ollama the context and the reserve, otherwise nil and the
    /// provider settings' maximum.
    func requestLimits(settings: ProviderSettings) -> (contextWindow: Int?, maxOutputTokens: Int?) {
        isOllama ? (context, reserve) : (nil, settings.maxOutputTokens)
    }

    init(descriptor: ProviderDescriptor, settings: ProviderSettings, model: ModelInfo?, job: Planning.Job, physicalMemoryBytes: UInt64) {
        let override = settings.contextWindowOverride.flatMap { $0 > 0 ? $0 : nil }
        let modelWindow = model?.contextWindow.flatMap { $0 > 0 ? $0 : nil }
        isCLI = descriptor.authMode == .subscriptionCLI
        isOllama = descriptor.id == "ollama"
        contextKnown = override != nil || modelWindow != nil
        context = override ?? modelWindow ?? (isCLI ? Planning.cliContextWindow : Planning.unknownContextWindow)
        reserve = job.outputReserve
        cappedFrom = nil
        if isOllama {
            let cap = override ?? Planning.ollamaContextCap(physicalMemoryBytes: physicalMemoryBytes)
            if context > cap { cappedFrom = context }
            context = min(context, cap)
            reserve = min(Planning.ollamaReserveCap, context / 4)
        }
        inputBudget = context - reserve - Planning.promptOverheadTokens - Planning.safetyTokens - (isCLI ? Planning.cliOverheadTokens : 0)
    }
}

/// What planning needs to know about a paper.
struct PaperMetrics: Equatable {
    var pages: Int
    var characters: Int          // of the rendered text
    var utf8Bytes: Int           // of the rendered text
    var fileBytes: Int
    var isEncrypted: Bool
    var hasTextLayer: Bool

    init(paper: LoadedPaper, rendered: String) {
        pages = max(paper.ref.pageCount, paper.text.pages.count)
        characters = rendered.count
        utf8Bytes = rendered.utf8.count
        fileBytes = paper.data.count
        isEncrypted = paper.isEncrypted
        hasTextLayer = paper.text.hasTextLayer
    }
}

/// A plan for one job: how the paper travels and in how many requests.
struct JobPlan {
    var sendPlan: SendPlan
    var budget: TokenBudget
    /// Page ranges (positions in `PaperText.pages`) of a review read in parts; empty for one pass.
    var parts: [Range<Int>]
    /// The PDF travels; otherwise the rendered text.
    var sendsPDF: Bool { sendPlan.sendsPDF }
}

enum Planner {
    /// Whether the file itself can be sent, and if not, why (nil when nothing needs saying: text mode was chosen, or the
    /// provider only takes text and the user did not ask for PDF). `allowance` is the number of input tokens the PDF may use.
    static func pdfDecision(descriptor: ProviderDescriptor, settings: ProviderSettings, model: ModelInfo?, metrics: PaperMetrics,
                            budget: TokenBudget, allowance: Int) -> (sendsPDF: Bool, warning: String?) {
        if settings.inputMode == .text { return (false, nil) }
        guard descriptor.supportsNativePDF else {
            return (false, settings.inputMode == .pdf ? "This provider does not accept PDF files, so the extracted text is sent instead." : nil)
        }
        if model?.supportsPDFInput == false {
            return (false, "The chosen model does not accept PDF files, so the extracted text is sent instead.")
        }
        if metrics.isEncrypted {
            return (false, "This PDF is protected, so its text is sent instead of the file.")
        }
        if metrics.fileBytes > Planning.maxPDFBytes {
            return (false, "The PDF file is larger than 30 MB, so its text is sent instead.")
        }
        if let limit = Planning.pdfPageLimit(provider: descriptor.id, context: budget.context), metrics.pages > limit {
            return (false, "The PDF has \(metrics.pages) pages, more than the \(limit) this provider accepts in one file, so its text is sent instead.")
        }
        let pdfTokens = metrics.pages * (Planning.pdfTokensPerPage[descriptor.id] ?? Planning.defaultPDFTokensPerPage)
        if pdfTokens > allowance {
            var warning = "The PDF (about \(grouped(pdfTokens)) tokens) does not fit the model's input budget of about \(grouped(max(0, allowance))) tokens, "
                + "so its text is sent instead."
            if !budget.contextKnown {
                warning += " The model's context window is not known yet, so \(grouped(budget.context)) tokens were assumed."
            }
            return (false, warning)
        }
        return (true, nil)
    }

    static func pdfTokens(descriptor: ProviderDescriptor, metrics: PaperMetrics) -> Int {
        metrics.pages * (Planning.pdfTokensPerPage[descriptor.id] ?? Planning.defaultPDFTokensPerPage)
    }

    /// The review plan of section 6.4. `forceText` is the automatic fallback after a provider refused the PDF.
    static func review(descriptor: ProviderDescriptor, context: EngineContext, paper: LoadedPaper, rendered: String, renderer: any PaperRendering,
                       physicalMemoryBytes: UInt64, forceText: Bool = false) -> JobPlan {
        let settings = context.providerSettings
        let metrics = PaperMetrics(paper: paper, rendered: rendered)
        let budget = TokenBudget(descriptor: descriptor, settings: settings, model: context.model, job: .review, physicalMemoryBytes: physicalMemoryBytes)
        func plan(sendsPDF: Bool = false, requests: Int = 0, tokens: Int = 0, warnings: [String?] = [], blocking: String? = nil,
                  parts: [Range<Int>] = []) -> JobPlan {
            JobPlan(sendPlan: SendPlan(sendsPDF: sendsPDF, requestCount: requests, estimatedInputTokens: tokens, destination: descriptor.destination,
                                       isLocal: descriptor.isLocal, warnings: warnings.compactMap { $0 }, blockingReason: blocking),
                    budget: budget, parts: parts)
        }
        guard budget.inputBudget >= Planning.minimumInputBudget else { return plan(blocking: Planning.contextTooSmall) }

        let (pdf, pdfWarning) = forceText
            ? (false, nil)
            : pdfDecision(descriptor: descriptor, settings: settings, model: context.model, metrics: metrics, budget: budget, allowance: budget.inputBudget)
        if pdf { return plan(sendsPDF: true, requests: 1, tokens: pdfTokens(descriptor: descriptor, metrics: metrics)) }
        guard metrics.hasTextLayer else { return plan(warnings: [pdfWarning], blocking: Planning.noTextLayer) }

        let byteLimit = descriptor.maxPromptBytes ?? Int.max
        let textFits = Double(metrics.characters) / Planning.charsPerToken <= Double(budget.inputBudget)
            && metrics.utf8Bytes <= byteLimit - Planning.promptBytesMargin
        if textFits { return plan(requests: 1, tokens: Planning.tokens(forCharacters: metrics.characters), warnings: [pdfWarning]) }

        let budgetCharacters = Int(Double(budget.inputBudget) * Planning.charsPerToken)
        let maxCharacters = max(1, min(budgetCharacters, byteLimit - Planning.promptBytesMargin) - Planning.notesBudgetChars)
        let parts = renderer.chunkPageRanges(paper.text, maxCharacters: maxCharacters).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return plan(requests: 1, tokens: Planning.tokens(forCharacters: metrics.characters), warnings: [pdfWarning]) }
        var ollamaWarning: String?
        if budget.isOllama, let modelWindow = budget.cappedFrom {
            ollamaWarning = "Ollama is given a context of \(grouped(budget.context)) tokens (the model allows \(grouped(modelWindow))), so the paper is read "
                + "in parts. A larger context window, set in Settings, would let it read the paper at once but needs more memory."
        }
        let partsWarning = "Paper will be read in \(parts.count) parts, then once more as a whole (\(parts.count + 1) requests)."
        let tokens = Planning.tokens(forCharacters: metrics.characters + parts.count * Planning.notesBudgetChars)
        return plan(requests: parts.count + 1, tokens: tokens, warnings: [pdfWarning, partsWarning, ollamaWarning], parts: parts)
    }

    /// How the paper travels in a discussion, a question or the report (section 6.3, "Paper context").
    enum PaperContextMode: Equatable {
        case pdf
        case fullText
        /// The digest, when there is one, and the pages around the passage, in at most `maxCharacters`.
        case excerpt(maxCharacters: Int)
    }

    static func paperContext(descriptor: ProviderDescriptor, context: EngineContext, paper: LoadedPaper, rendered: String, job: Planning.Job,
                             physicalMemoryBytes: UInt64, forceText: Bool = false) -> (mode: PaperContextMode, budget: TokenBudget) {
        let metrics = PaperMetrics(paper: paper, rendered: rendered)
        let budget = TokenBudget(descriptor: descriptor, settings: context.providerSettings, model: context.model, job: job,
                                 physicalMemoryBytes: physicalMemoryBytes)
        let allowance = Int(Double(max(0, budget.inputBudget)) * Planning.paperContextShare)
        if !forceText,
           pdfDecision(descriptor: descriptor, settings: context.providerSettings, model: context.model, metrics: metrics, budget: budget,
                       allowance: allowance).sendsPDF {
            return (.pdf, budget)
        }
        let byteLimit = descriptor.maxPromptBytes ?? Int.max
        if Double(metrics.characters) / Planning.charsPerToken <= Double(allowance), metrics.utf8Bytes <= byteLimit - Planning.promptBytesMargin {
            return (.fullText, budget)
        }
        let characters = min(Int(Double(allowance) * Planning.charsPerToken), byteLimit - Planning.promptBytesMargin)
        return (.excerpt(maxCharacters: max(1_000, characters)), budget)
    }

    /// 153000 -> "153,000": the same on every machine, whatever its locale.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var result = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return number < 0 ? "-" + result : result
    }
}
