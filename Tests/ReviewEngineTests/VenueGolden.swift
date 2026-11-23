import Foundation
import CryptoKit
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// Every kind of request the engine sends, for a paper whose venue adds nothing to the prompts ("Journal (unspecified)",
/// plan.md Appendix G.9), serialised so that two runs can be compared byte for byte. `VenueJournalTests` holds the
/// SHA-256 of each serialisation as the code produced it at commit c1c6ee3, before venues existed.
enum VenueGolden {
    typealias Adjust = @Sendable (inout EngineContext) -> Void

    static let notes = "Focus on identification.\nIgnore the typos."
    static let freeTextVenue = "Journal of Examples"
    static let fullMeta = ManuscriptMeta(targetVenue: freeTextVenue, reviewerNotes: notes)
    static let bareMeta = ManuscriptMeta(reviewerNotes: "")
    static let digest = "DIGEST: the paper asks whether disclosure slows herding; p.4: Page 4 marker"

    /// One request as text: purpose, model and limits, the system prompt, then every part in order.
    static func serialize(_ request: LLMRequest) -> String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        var text = "purpose=\(request.purpose.rawValue) model=\(request.model ?? "-") max=\(number(request.maxOutputTokens)) "
            + "context=\(number(request.contextWindow))\n== system\n\(request.system)\n"
        for part in request.parts {
            switch part {
            case .text(let value): text += "== text\n\(value)\n"
            case .pdf(let data, let fileName): text += "== pdf \(fileName) \(data.count) bytes\n"
            case .cacheBoundary: text += "== cache boundary\n"
            }
        }
        return text
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The requests of every scenario, named "<scenario>#<n>", in the order they were sent. `adjust` changes each
    /// context before the job runs (the venue tests give it a venue).
    static func requests(_ adjust: @escaping Adjust = { _ in }) async throws -> [(name: String, request: LLMRequest)] {
        var all: [(String, LLMRequest)] = []
        func add(_ scenario: String, _ requests: [LLMRequest]) {
            for (position, request) in requests.enumerated() { all.append(("\(scenario)#\(position + 1)", request)) }
        }
        add("review.text.full", try await review(adjust, pdf: false, meta: fullMeta, existing: existing))
        add("review.text.bare", try await review(adjust, pdf: false, meta: bareMeta, existing: []))
        add("review.pdf.full", try await review(adjust, pdf: true, meta: fullMeta, existing: existing))
        add("review.pdf.bare", try await review(adjust, pdf: true, meta: bareMeta, existing: []))
        add("review.parts", try await reviewInParts(adjust))
        add("review.continued", try await reviewContinued(adjust))
        add("discuss.text", try await discuss(adjust, pdf: false))
        add("discuss.pdf", try await discuss(adjust, pdf: true))
        add("discuss.excerpt", try await discussLargePaper(adjust))
        add("ask.selection", try await ask(adjust, anchored: true))
        add("ask.general", try await ask(adjust, anchored: false))
        add("ask.excerpt", try await askLargePaper(adjust))
        add("report.text.full", try await report(adjust, pdf: false, meta: fullMeta))
        add("report.text.bare", try await report(adjust, pdf: false, meta: bareMeta))
        add("report.pdf", try await report(adjust, pdf: true, meta: fullMeta))
        add("report.excerpt", try await reportLargePaper(adjust))
        add("revise", try await revise(adjust))
        return all
    }

    /// Report texts for the style check and the recommendation, with what the journal rules find in each.
    static func reportTexts() throws -> [(name: String, markdown: String)] {
        [
            ("sample", try Fixtures.text("llm/report_sample.txt")),
            ("clean", LintTests.report()),
            ("accept-with-majors", LintTests.report(recommendation: "Accept. The result stands.")),
            ("reject-without-majors", LintTests.report(recommendation: "Reject. I do not believe it.", major: [])),
            ("accept-with-minor-revisions", LintTests.report(recommendation: "Accept with minor revisions.", major: [])),
            ("bold-headings", "**Summary assessment**\n\nFine.\n\n**Recommendation**\n\nMinor revision.\n\n**Chance of acceptance**\n\n30%.\n"),
            ("weak-accept", LintTests.report(recommendation: "Weak accept. The result is new.", major: [])),
            ("no-sections", "I would reject this paper — it is not novel.\n"),
        ]
    }

    /// What the style check and the recommendation parser make of a report text, one line per finding.
    static func serialize(findings: [LintFinding], recommendation: Recommendation?) -> String {
        findings.map { "\($0.id) \($0.rule) \($0.range.location)+\($0.range.length) \($0.message)" }.joined(separator: "\n")
            + "\nrecommendation=\(recommendation?.rawValue ?? "-")\n"
    }

    // ---- scenarios ----

    private static func context(_ adjust: Adjust, model: ModelInfo?, settings: ProviderSettings = ProviderSettings(enabled: true, inputMode: .auto),
                                meta: ManuscriptMeta, digest: String? = nil) -> EngineContext {
        var context = EngineTest.context(model: model, settings: settings, meta: meta, digest: digest)
        adjust(&context)
        return context
    }

    private static func earlier(_ title: String, _ status: CommentStatus) -> ReviewComment {
        ReviewComment(id: UUID(), origin: .user, status: status, kind: .minor, category: "other", title: title, body: "b",
                      anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: Date(), updatedAt: Date())
    }

    private static var existing: [ReviewComment] {
        [earlier("First earlier comment", .approved), earlier("Rejected one", .rejected), earlier("Second earlier comment", .pending)]
    }

    private static func review(_ adjust: Adjust, pdf: Bool, meta: ManuscriptMeta, existing: [ReviewComment]) async throws -> [LLMRequest] {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(supportsNativePDF: pdf)
        let context = context(adjust, model: try await mock.listModels().first, meta: meta)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: existing, context: context))
        return mock.recordedRequests
    }

    private static func block(page: Int, quote: String, title: String) -> String {
        "@@COMMENT\nkind: minor\ncategory: claims\npage: \(page)\nquote: \(quote)\ntitle: \(title)\nbody:\nThe body of \(title).\n@@END\n"
    }

    private static func reviewInParts(_ adjust: Adjust) async throws -> [LLMRequest] {
        let paper = EngineTest.paper(pageCount: 3, charactersPerPage: 10_000)
        let model = ModelInfo(id: "mock", displayName: "mock", contextWindow: 4_000 + 16_000 + 3_000 + 1_024)
        let answers = [
            block(page: 1, quote: "Page 1 marker", title: "On part one") + "@@NOTES\nNOTES-ONE: the question and the design.\np.1: Page 1 marker\n@@DONE\n",
            block(page: 2, quote: "Page 2 marker", title: "On part two") + "@@NOTES\nNOTES-TWO: what part two adds.\n@@DONE\n",
            "@@NOTES\nNOTES-THREE: the final notes on all three parts.\n@@DONE\n",
            block(page: 3, quote: "Page 3 marker", title: "On the whole paper") + "@@DONE\n",
        ].map { MockResponse(text: $0, chunkSize: 11) }
        let mock = MockLLMProvider(script: EngineTest.script(.review, answers))
        let context = context(adjust, model: model, meta: fullMeta)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: existing, context: context))
        return mock.recordedRequests
    }

    private static func reviewContinued(_ adjust: Adjust) async throws -> [LLMRequest] {
        let cut = block(page: 1, quote: "Our identification strategy exploits", title: "First comment")
            + "@@COMMENT\nkind: minor\ncategory: math\npage: 2\nquote: Proposition 1 states\ntitle: Second comment, cut off\nbody:\nThe body stops"
        let answers = [MockResponse(text: cut, stop: .maxTokens), MockResponse(text: block(page: 2, quote: "Proposition 1", title: "Third comment") + "@@DONE\n")]
        let mock = MockLLMProvider(script: EngineTest.script(.review, answers))
        let paper = try makeSamplePaper()
        let context = context(adjust, model: try await mock.listModels().first, meta: fullMeta)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).review(paper: paper, existing: [], context: context))
        return mock.recordedRequests
    }

    private static func comment(page: Int? = 0, quote: String = "The coefficient in Table 2 is 0.91", label: String = "p. 1, lines 13–14",
                                status: CommentStatus = .pending, thread: [ThreadMessage] = []) -> ReviewComment {
        let anchor = page.map { Anchor(quote: quote, pageIndex: $0, confidence: .pageOnly, locationLabel: label) }
            ?? Anchor(quote: quote, confidence: .none, locationLabel: "")
        return ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: status, kind: .major, category: "claims",
                             title: "The interval includes one, yet the effect is called robust", body: "The data are consistent with no effect.",
                             suggestion: "Drop \"robust\".", anchor: anchor, thread: thread, includeInReport: true, createdAt: Date(), updatedAt: Date())
    }

    private static var thread: [ThreadMessage] {
        [ThreadMessage(id: UUID(), role: .user, text: "Is the interval really in the text?", createdAt: Date()),
         ThreadMessage(id: UUID(), role: .assistant, text: "Yes, in the introduction.", createdAt: Date()),
         ThreadMessage(id: UUID(), role: .user, text: "Then soften the comment.", createdAt: Date())]
    }

    private static func discuss(_ adjust: Adjust, pdf: Bool) async throws -> [LLMRequest] {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider(supportsNativePDF: pdf)
        let context = context(adjust, model: try await mock.listModels().first, meta: fullMeta)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .discuss(paper: paper, comment: comment(thread: thread), message: "Then soften the comment.", context: context))
        return mock.recordedRequests
    }

    /// Six pages of about 4,000 characters and a context of 16,000 tokens: replies get the digest and an excerpt.
    private static let largePaper = EngineTest.paper(pageCount: 6, charactersPerPage: 4_000)
    private static let smallContext = ProviderSettings(enabled: true, contextWindowOverride: 16_000, inputMode: .auto)

    private static func discussLargePaper(_ adjust: Adjust) async throws -> [LLMRequest] {
        let mock = MockLLMProvider()
        let context = context(adjust, model: try await mock.listModels().first, settings: smallContext, meta: fullMeta, digest: digest)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: largePaper)
            .discuss(paper: largePaper, comment: comment(page: 3, quote: "Page 4 marker", label: "p. 4"), message: "Is this right?", context: context))
        return mock.recordedRequests
    }

    private static var history: [ThreadMessage] {
        [ThreadMessage(id: UUID(), role: .user, text: "What is the main claim?", createdAt: Date()),
         ThreadMessage(id: UUID(), role: .assistant, text: "That disclosure slows herding.", createdAt: Date())]
    }

    private static func ask(_ adjust: Adjust, anchored: Bool) async throws -> [LLMRequest] {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let anchor = Anchor(quote: "The effect is statistically significant but economically small.", pageIndex: 0, confidence: .exact,
                            locationLabel: "p. 1, line 9")
        let conversation = Conversation(id: UUID(), anchor: anchored ? anchor : nil, messages: history, createdAt: Date())
        let context = context(adjust, model: try await mock.listModels().first, meta: fullMeta)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .ask(paper: paper, conversation: conversation, question: "Is the claim in the abstract supported?", context: context))
        return mock.recordedRequests
    }

    private static func askLargePaper(_ adjust: Adjust) async throws -> [LLMRequest] {
        let mock = MockLLMProvider()
        let conversation = Conversation(id: UUID(), anchor: Anchor(quote: "Page 6 marker", pageIndex: 5, confidence: .exact, locationLabel: "p. 6"),
                                        createdAt: Date())
        let context = context(adjust, model: try await mock.listModels().first, settings: smallContext, meta: fullMeta, digest: digest)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: largePaper).ask(paper: largePaper, conversation: conversation, question: "Why?",
                                                                                         context: context))
        return mock.recordedRequests
    }

    private static func reportComments(on paper: LoadedPaper) -> [ReviewComment] {
        func make(_ title: String, _ kind: CommentKind, page: Int?, line: Int?, label: String, created: TimeInterval) -> ReviewComment {
            var spans: [TextSpan] = []
            if let page, let line { spans = [TextSpan(pageIndex: page, range: paper.text.pages[page].lines[line].contentRange)] }
            let confidence: AnchorConfidence = page == nil ? .none : (spans.isEmpty ? .pageOnly : .exact)
            return ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: .approved, kind: kind, category: kind == .major ? "claims" : "data",
                                 title: title, body: "Body of \(title).", suggestion: kind == .major ? "Fix \(title)." : nil,
                                 anchor: Anchor(quote: "Quote of \(title)", spans: spans, pageIndex: page, confidence: confidence, locationLabel: label),
                                 includeInReport: true, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created))
        }
        return [make("Major on page two", .major, page: 1, line: 0, label: "p. 2, line 1", created: 1),
                make("Strength", .strength, page: 0, line: 0, label: "p. 1", created: 2),
                make("Minor, page only", .minor, page: 0, line: nil, label: "p. 1", created: 3),
                make("Question without a place", .question, page: nil, line: nil, label: "", created: 4),
                make("Major on page one", .major, page: 0, line: 1, label: "p. 1, line 2", created: 5)]
    }

    private static func report(_ adjust: Adjust, pdf: Bool, meta: ManuscriptMeta) async throws -> [LLMRequest] {
        let paper = pdf ? try makeSamplePaper() : EngineTest.paper(pages: [
            ["Line one of page one.", "Line two of page one.", "Line three of page one."],
            ["Line one of page two.", "Line two of page two."],
        ])
        let comments = pdf ? [comment(status: .approved)] : reportComments(on: paper)
        let mock = MockLLMProvider(supportsNativePDF: pdf)
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: meta, comments: comments,
                                    report: ReportDraft(markdown: "Old.", userEdited: true), createdAt: Date(), updatedAt: Date())
        let context = context(adjust, model: try await mock.listModels().first, meta: meta)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: paper).generateReport(paper: paper, session: session, context: context))
        return mock.recordedRequests
    }

    private static func reportLargePaper(_ adjust: Adjust) async throws -> [LLMRequest] {
        let mock = MockLLMProvider()
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: largePaper.ref, meta: fullMeta,
                                    comments: [comment(page: 3, quote: "Page 4 marker", label: "p. 4", status: .approved)], createdAt: Date(), updatedAt: Date())
        let settings = ProviderSettings(enabled: true, contextWindowOverride: 20_000, inputMode: .auto)
        let context = context(adjust, model: try await mock.listModels().first, settings: settings, meta: fullMeta, digest: digest)
        _ = try await EngineTest.collect(EngineTest.engine([mock], paper: largePaper).generateReport(paper: largePaper, session: session, context: context))
        return mock.recordedRequests
    }

    private static func revise(_ adjust: Adjust) async throws -> [LLMRequest] {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: paper)
        let report = try Fixtures.text("llm/report_sample.txt")
        let context = context(adjust, model: try await mock.listModels().first, meta: fullMeta)
        _ = try await EngineTest.collect(engine.reviseVoice(draft: ReportDraft(markdown: report, userEdited: false),
                                                            findings: engine.lint(reportMarkdown: report), context: context))
        return mock.recordedRequests
    }
}
