import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The words of plan.md section 9.7 and of the design review (D12, D20, D24, D34): the facts of the destination menu
/// and of the consent card, the plan sentence, the question before a second review and what was sent so far.
@Suite struct ShellPlanTextTests {
    private typealias Sample = ShellTestData

    // ---- the plan sentence ----

    @Test func aPDFPlanNamesTheFileTheRequestsTheTokensAndTheHost() {
        let plan = Sample.plan(pdf: true, tokens: 153_412, to: "api.anthropic.com")
        #expect(ShellPlanText.sentence(plan: plan, descriptor: Sample.anthropic)
                == "A review will send the PDF file in 1 request, about 153,000 tokens, to api.anthropic.com.")
    }

    /// D12: a CLI is named by its short name, not its binary.
    @Test func theDeliveryNoteFollowsInBrackets() {
        let plan = Sample.plan(pdf: true, tokens: 41_250, to: "codex")
        #expect(ShellPlanText.sentence(plan: plan, descriptor: Sample.codex)
                == "A review will send the PDF file in 1 request, about 41,000 tokens, to OpenAI through Codex (sent as page images).")
        #expect(ShellPlanText.destinationPhrase(plan: plan, descriptor: Sample.claude) == "to Anthropic through Claude Code")
    }

    @Test func aTextPlanAddsTheFixedSentenceForEveryProvider() {
        let local = Sample.plan(pdf: false, requests: 3, tokens: 60_912, to: "127.0.0.1:11434", local: true)
        #expect(ShellPlanText.sentence(plan: local, descriptor: Sample.ollama)
                == "A review will send the extracted text in 3 requests, about 61,000 tokens, to 127.0.0.1:11434. "
                + "Extracted text only: equations and tables may reach the model garbled.")
        let remote = Sample.plan(pdf: false, tokens: 912, to: "api.x.ai")
        #expect(ShellPlanText.sentence(plan: remote, descriptor: Sample.xai)
                == "A review will send the extracted text in 1 request, about 910 tokens, to api.x.ai. " + ShellPlanText.textOnlyWarning)
        let cli = Sample.plan(pdf: false, tokens: 9_000, to: "agy")
        #expect(ShellPlanText.sentence(plan: cli, descriptor: Sample.antigravity).hasSuffix("to Google through Antigravity. " + ShellPlanText.textOnlyWarning))
    }

    // ---- the destination menu (D24) ----

    @Test func theMenuShowsTheFactsThenTheWarningsAndABlockingReasonAlone() {
        let warned = Sample.plan(pdf: false, requests: 7, tokens: 61_000, to: "127.0.0.1:11434", local: true,
                                 warnings: ["Paper will be read in 6 parts, then once more as a whole (7 requests).", ""])
        let summary = ShellPlanText.menuSummary(plan: warned, descriptor: Sample.ollama, pageCount: 16, byteCount: 500_000)
        #expect(summary.facts == [ShellConsentFact(label: "Sends", value: "Extracted text of 16 pages"),
                                  ShellConsentFact(label: "To", value: "127.0.0.1:11434"),
                                  ShellConsentFact(label: "Requests", value: "7 · about 61,000 tokens"),
                                  ShellConsentFact(label: "", value: ShellPlanText.textOnlyWarning, isWarning: true)])
        #expect(summary.warnings == ["Paper will be read in 6 parts, then once more as a whole (7 requests)."])
        #expect(summary.blockingReason == nil)

        let blocked = Sample.plan(pdf: false, requests: 0, tokens: 0, to: "127.0.0.1:11434", local: true, warnings: ["ignored"],
                                  blocking: "This PDF has no text layer; choose a provider that reads PDF files.")
        #expect(ShellPlanText.menuSummary(plan: blocked, descriptor: Sample.ollama, pageCount: 1, byteCount: 1)
                == ShellPlanSummary(facts: [], warnings: [], blockingReason: "This PDF has no text layer; choose a provider that reads PDF files."))
    }

    @Test func aPDFPlanSaysTheSizeAndHowTheFileGoes() {
        let plan = Sample.plan(pdf: true, tokens: 41_250, to: "codex")
        let summary = ShellPlanText.menuSummary(plan: plan, descriptor: Sample.codex, pageCount: 4, byteCount: 165_000)
        #expect(summary.facts.map(\.value) == ["The PDF file · 165 KB · 4 pages", "OpenAI, through Codex", "1 · about 41,000 tokens · sent as page images"])
        #expect(!summary.facts.contains { $0.isWarning })
    }

    // ---- the consent card (D12) ----

    @Test func theConsentCardOfAPDFPlanIsFacts() {
        let request = ConsentRequest(provider: Sample.anthropic, model: "example-large", plan: Sample.plan(pdf: true, tokens: 153_000, to: "api.anthropic.com"))
        let text = ShellPlanText.consent(request: request, pageCount: 34, byteCount: 2_100_000)
        #expect(text.title == "Send this manuscript to Anthropic?")
        #expect(text.provider == "Anthropic API · example-large")
        #expect(text.what == "The PDF file (2.1 MB, 34 pages) will be sent to api.anthropic.com in 1 request (about 153,000 tokens).")
        #expect(text.facts == [ShellConsentFact(label: "What", value: "The PDF file · 2.1 MB · 34 pages"),
                               ShellConsentFact(label: "To", value: "api.anthropic.com"),
                               ShellConsentFact(label: "Requests", value: "1 · about 153,000 tokens"),
                               ShellConsentFact(label: "Kept", value: "Sent to Anthropic under your API account's data terms.")])
        #expect(text.again == "Later questions, discussions and the report will send it again to the same provider.")
        #expect(text.policy == "Check the journal's policy on AI tools before sending a manuscript under review.")
        #expect(text.blockingReason == nil)
        #expect(text.sendButton == "Send to Anthropic")
        #expect(ShellPlanText.dontSend == "Don't Send")
        #expect(text.lines.count == 8)
    }

    @Test func theConsentCardOfATextPlanCarriesTheTextOnlyWarning() {
        let request = ConsentRequest(provider: Sample.xai, model: "example-chat", plan: Sample.plan(pdf: false, requests: 2, tokens: 30_400, to: "api.x.ai"))
        let text = ShellPlanText.consent(request: request, pageCount: 1, byteCount: 300)
        #expect(text.what == "The extracted text (1 page) will be sent to api.x.ai in 2 requests (about 30,000 tokens). "
                + "Extracted text only: equations and tables may reach the model garbled.")
        #expect(text.facts.map(\.label) == ["What", "To", "Requests", "Kept", ""])
        #expect(text.facts.first?.value == "Extracted text of 1 page")
        #expect(text.facts.last == ShellConsentFact(label: "", value: ShellPlanText.textOnlyWarning, isWarning: true))
        #expect(text.sendButton == "Send to xAI")
    }

    @Test func aSubscriptionCLIIsNamedByItsVendorAndItsShortName() {
        let plan = Sample.plan(pdf: true, tokens: 20_000, to: "codex", warnings: ["This PDF is protected, so its text is sent instead of the file"])
        let request = ConsentRequest(provider: Sample.codex, model: nil, plan: plan)
        let text = ShellPlanText.consent(request: request, pageCount: 4, byteCount: 183_964)
        #expect(text.title == "Send this manuscript to OpenAI?")
        #expect(text.provider == "Codex (ChatGPT plan) · default")
        #expect(text.what == "The PDF file (184 KB, 4 pages) will be sent to OpenAI through Codex in 1 request (about 20,000 tokens; sent as page images).")
        #expect(text.facts.map(\.value) == ["The PDF file · 184 KB · 4 pages", "OpenAI, through Codex", "1 · about 20,000 tokens · sent as page images",
                                            Sample.codex.retentionNote])
        #expect(text.warnings == ["This PDF is protected, so its text is sent instead of the file"])
        #expect(text.lines == [text.title, text.provider, "What: The PDF file · 184 KB · 4 pages", "To: OpenAI, through Codex",
                               "Requests: 1 · about 20,000 tokens · sent as page images", "Kept: " + Sample.codex.retentionNote, text.again,
                               "This PDF is protected, so its text is sent instead of the file", text.policy])
    }

    @Test func aBlockingReasonIsShownLast() {
        let plan = Sample.plan(pdf: false, requests: 0, tokens: 0, to: "agy", blocking: "The paper does not fit.")
        let text = ShellPlanText.consent(request: ConsentRequest(provider: Sample.antigravity, plan: plan), pageCount: 2, byteCount: 10)
        #expect(text.blockingReason == "The paper does not fit.")
        #expect(text.lines.last == "The paper does not fit.")
    }

    // ---- a second review (D20), what was sent (D34) ----

    @Test func aSecondReviewSaysWhatItCostsAndThatNothingIsRemoved() {
        let plan = Sample.plan(pdf: true, tokens: 18_200, to: "claude")
        #expect(ShellPlanText.reviewAgain(plan: plan, descriptor: Sample.claude)
                == "The model reads the paper again: about 18,000 tokens to Anthropic through Claude Code. "
                + "New comments are added next to the existing ones; nothing is removed.")
        #expect(ShellPlanText.reviewAgain(plan: Sample.plan(pdf: true, tokens: 153_000, to: "api.anthropic.com"), descriptor: Sample.anthropic)
                .hasPrefix("The model reads the paper again: about 153,000 tokens to api.anthropic.com. "))
        #expect(ShellPlanText.reviewAgainTitle == "Review this paper again?")
    }

    @Test func whatWasSentIsOneLinePerProviderTheLastUsedFirst() {
        func run(_ provider: ProviderID, at seconds: Double, pdf: Bool, kind: RunKind = .review) -> RunRecord {
            RunRecord(id: UUID(), kind: kind, provider: ProviderRef(providerID: provider, model: nil), destination: "", sentPDF: pdf,
                      requestCount: 1, startedAt: Date(timeIntervalSince1970: seconds), status: .completed)
        }
        let runs = [run("mock", at: 100, pdf: false), run("anthropic-api", at: 200, pdf: true), run("mock", at: 300, pdf: false, kind: .discussion),
                    run("anthropic-api", at: 150, pdf: false, kind: .question)]
        let names: [ProviderID: String] = ["mock": "Mock", "anthropic-api": "Anthropic API"]
        let lines = ShellPlanText.sentSoFar(runs, name: { names[$0] ?? $0 }, date: { "t\(Int($0.timeIntervalSince1970))" })
        #expect(lines == ["Mock: 2 times, last t300 (extracted text)", "Anthropic API: 2 times, last t200 (PDF file and extracted text)"])
        #expect(ShellPlanText.sentSoFar([run("gone", at: 5, pdf: true)], name: { $0 }, date: { _ in "then" }) == ["gone: 1 time, last then (PDF file)"])
        #expect(ShellPlanText.sentSoFar([], name: { $0 }, date: { _ in "" }).isEmpty)
        #expect(ShellPlanText.nothingSent == "Nothing has been sent yet.")
    }

    // ---- numbers ----

    @Test func numbersAreGroupedAndRoundedTheSameEverywhere() {
        #expect(ShellFormat.grouped(0) == "0")
        #expect(ShellFormat.grouped(999) == "999")
        #expect(ShellFormat.grouped(1_000) == "1,000")
        #expect(ShellFormat.grouped(153_000) == "153,000")
        #expect(ShellFormat.grouped(1_234_567) == "1,234,567")
        #expect(ShellFormat.grouped(-4_500) == "-4,500")
        #expect(ShellFormat.approximately(153_456) == "153,000")
        #expect(ShellFormat.approximately(60_912) == "61,000")
        #expect(ShellFormat.approximately(4_321) == "4,300")
        #expect(ShellFormat.approximately(905) == "910")
        #expect(ShellFormat.approximately(-5) == "0")
        #expect(ShellFormat.bytes(1) == "1 byte")
        #expect(ShellFormat.bytes(640) == "640 bytes")
        #expect(ShellFormat.bytes(183_964) == "184 KB")
        #expect(ShellFormat.bytes(2_100_000) == "2.1 MB")
        #expect(ShellFormat.bytes(999_960) == "1.0 MB")                     // not "1,000 KB"
        #expect(ShellFormat.bytes(999_960_000) == "1.0 GB")
        #expect(ShellFormat.bytes(1_340_000_000) == "1.3 GB")
        #expect(ShellFormat.count(1, "request", "requests") == "1 request")
        #expect(ShellFormat.count(12, "request", "requests") == "12 requests")
    }
}
