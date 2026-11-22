import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
@testable import RefereeUI

// Helpers of the Shell's tests: descriptors and plans written as literals, and a review model on fakes that opens the
// sample paper with a session of the test's own comments.

enum ShellTestData {
    static let anthropic = ProviderDescriptor(id: "anthropic-api", displayName: "Anthropic API", vendor: "Anthropic", authMode: .apiKey,
                                              isLocal: false, destination: "api.anthropic.com", supportsNativePDF: true, streaming: .token,
                                              retentionNote: "Sent to Anthropic under your API account's data terms.", isExperimental: false)
    static let ollama = ProviderDescriptor(id: "ollama", displayName: "Ollama (local)", vendor: "Ollama", authMode: .local, isLocal: true,
                                           destination: "127.0.0.1:11434", supportsNativePDF: false, streaming: .token,
                                           retentionNote: "Processed on this Mac; nothing is sent.", isExperimental: false)
    static let claude = ProviderDescriptor(id: "claude-cli", displayName: "Claude Code (subscription)", vendor: "Anthropic",
                                           authMode: .subscriptionCLI, isLocal: false, destination: "claude", supportsNativePDF: true,
                                           streaming: .token, maxPromptBytes: 9_000_000,
                                           retentionNote: "Runs through your Claude Code login with its tools switched off; no session transcript is saved.",
                                           isExperimental: false)
    static let codex = ProviderDescriptor(id: "codex-cli", displayName: "Codex (ChatGPT plan)", vendor: "OpenAI", authMode: .subscriptionCLI,
                                          isLocal: false, destination: "codex", supportsNativePDF: true, pdfDeliveryNote: "sent as page images",
                                          streaming: .message, maxPromptBytes: 4_000_000,
                                          retentionNote: "Runs through your ChatGPT plan with shell and agent tools switched off; session files are not kept.",
                                          isExperimental: false)
    static let antigravity = ProviderDescriptor(id: "antigravity-cli", displayName: "Antigravity (Google AI plan)", vendor: "Google",
                                                authMode: .subscriptionCLI, isLocal: false, destination: "agy", supportsNativePDF: false,
                                                streaming: .token, maxPromptBytes: 4_000_000,
                                                retentionNote: "Runs through your Google account. Its tools cannot be switched off: Referee stops the run if it uses one. The CLI may keep a local conversation record.",
                                                isExperimental: true)
    static let xai = ProviderDescriptor(id: "xai-api", displayName: "xAI API", vendor: "xAI", authMode: .apiKey, isLocal: false,
                                        destination: "api.x.ai", supportsNativePDF: false, streaming: .token,
                                        retentionNote: "Sent to an endpoint that does not store requests.", isExperimental: false)

    static func plan(pdf: Bool, requests: Int = 1, tokens: Int, to destination: String, local: Bool = false, warnings: [String] = [],
                     blocking: String? = nil) -> SendPlan {
        SendPlan(sendsPDF: pdf, requestCount: requests, estimatedInputTokens: tokens, destination: destination, isLocal: local,
                 warnings: warnings, blockingReason: blocking)
    }

    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// A pending AI comment on a page, without a passage (page-only), so that the order is the order of the pages.
    static func comment(_ title: String, page: Int, status: CommentStatus = .pending, kind: CommentKind = .minor) -> ReviewComment {
        ReviewComment(id: UUID(), origin: .ai(runID: UUID()), status: status, kind: kind, category: "other", title: title, body: "Body of \(title).",
                      anchor: Anchor(quote: "", pageIndex: page, confidence: .pageOnly, locationLabel: "p. \(page + 1)"),
                      includeInReport: false, createdAt: date, updatedAt: date)
    }
}

@MainActor enum ShellTestModels {
    /// A review model on fakes, with `ay_round_nolinks.pdf` open and a stored session holding `comments`.
    static func opened(with comments: [ReviewComment], autoAdvance: Bool = true) async throws -> ReviewSessionModel {
        let paper = try makeSamplePaper()
        let store = InMemorySessionStore()
        var document = paper.ref
        document.fileName = "ay_round_nolinks.pdf"
        try await store.save(ReviewSession(schemaVersion: 1, id: UUID(), document: document, meta: ManuscriptMeta(reviewerNotes: ""),
                                           comments: comments, createdAt: ShellTestData.date, updatedAt: ShellTestData.date))
        let plan = SendPlan(sendsPDF: false, requestCount: 1, estimatedInputTokens: 0, destination: "this Mac", isLocal: true)
        let dependencies = AppDependencies(paperService: FakePaperService(paper: paper), matcherFactory: { FakeQuoteMatcher(paper: $0) },
                                           citationIndexer: FakeCitationIndexer(), engine: ScriptedReviewEngine(plan: plan), resolver: FakeResolver(),
                                           sessions: store, settings: InMemorySettingsStore(), providers: ProviderRegistry([]),
                                           secrets: InMemorySecretStore())
        var settings = DefaultSettings.make()
        settings.ui.autoAdvanceAfterTriage = autoAdvance
        let model = ReviewSessionModel(dependencies: dependencies, settings: settings)
        await model.open(url: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        try #require(model.phase == .ready)
        try #require(model.session?.comments.count == comments.count)
        return model
    }
}
