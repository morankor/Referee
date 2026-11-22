import Foundation
import Testing
import RefereeCore
import AppCore
@testable import RefereeUI

/// The words of plan.md section 9.7: the plan sentence of the destination menu and the consent card, from a SendPlan
/// and a descriptor.
@Suite struct ShellPlanTextTests {
    private typealias Sample = ShellTestData

    // ---- the plan sentence ----

    @Test func aPDFPlanNamesTheFileTheRequestsTheTokensAndTheHost() {
        let plan = Sample.plan(pdf: true, tokens: 153_412, to: "api.anthropic.com")
        #expect(ShellPlanText.sentence(plan: plan, descriptor: Sample.anthropic)
                == "A review will send the PDF file in 1 request, about 153,000 tokens, to api.anthropic.com.")
    }

    @Test func theDeliveryNoteFollowsInBrackets() {
        let plan = Sample.plan(pdf: true, tokens: 41_250, to: "codex")
        #expect(ShellPlanText.sentence(plan: plan, descriptor: Sample.codex)
                == "A review will send the PDF file in 1 request, about 41,000 tokens, to OpenAI through codex (sent as page images).")
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
        #expect(ShellPlanText.sentence(plan: cli, descriptor: Sample.antigravity).hasSuffix("to Google through agy. " + ShellPlanText.textOnlyWarning))
    }

    @Test func theMenuListsTheWarningsAfterTheSentenceAndABlockingReasonAlone() {
        let warned = Sample.plan(pdf: false, requests: 7, tokens: 61_000, to: "127.0.0.1:11434", local: true,
                                 warnings: ["Paper will be read in 6 parts, then once more as a whole (7 requests).", ""])
        let lines = ShellPlanText.menuLines(plan: warned, descriptor: Sample.ollama)
        #expect(lines.map(\.style) == [.normal, .warning])
        #expect(lines[1].text == "Paper will be read in 6 parts, then once more as a whole (7 requests).")

        let blocked = Sample.plan(pdf: false, requests: 0, tokens: 0, to: "127.0.0.1:11434", local: true, warnings: ["ignored"],
                                  blocking: "This PDF has no text layer; choose a provider that reads PDF files.")
        #expect(ShellPlanText.menuLines(plan: blocked, descriptor: Sample.ollama)
                == [ShellPlanLine(text: "This PDF has no text layer; choose a provider that reads PDF files.", style: .blocking)])
    }

    // ---- the consent card ----

    @Test func theConsentCardOfAPDFPlanReadsAsTheMockUp() {
        let request = ConsentRequest(provider: Sample.anthropic, model: "example-large", plan: Sample.plan(pdf: true, tokens: 153_000, to: "api.anthropic.com"))
        let text = ShellPlanText.consent(request: request, pageCount: 34, byteCount: 2_100_000)
        #expect(text.title == "Send this manuscript to Anthropic?")
        #expect(text.provider == "Anthropic API · example-large")
        #expect(text.what == "The PDF file (2.1 MB, 34 pages) will be sent to api.anthropic.com in 1 request (about 153,000 tokens).")
        #expect(text.again == "Later questions, discussions and the report will send it again to the same provider.")
        #expect(text.policy == "Check the journal's policy on AI tools before sending a manuscript under review.")
        #expect(text.retention == nil)                       // an API provider: no extra line
        #expect(text.blockingReason == nil)
        #expect(text.lines.count == 5)
    }

    @Test func theConsentCardOfATextPlanCarriesTheTextOnlySentence() {
        let request = ConsentRequest(provider: Sample.xai, model: "example-chat", plan: Sample.plan(pdf: false, requests: 2, tokens: 30_400, to: "api.x.ai"))
        let text = ShellPlanText.consent(request: request, pageCount: 1, byteCount: 300)
        #expect(text.what == "The extracted text (1 page) will be sent to api.x.ai in 2 requests (about 30,000 tokens). "
                + "Extracted text only: equations and tables may reach the model garbled.")
    }

    @Test func aSubscriptionCLIAddsWhatSection125SaysAboutIt() {
        let plan = Sample.plan(pdf: true, tokens: 20_000, to: "codex", warnings: ["This PDF is protected, so its text is sent instead of the file"])
        let request = ConsentRequest(provider: Sample.codex, model: nil, plan: plan)
        let text = ShellPlanText.consent(request: request, pageCount: 4, byteCount: 183_964)
        #expect(text.title == "Send this manuscript to OpenAI?")
        #expect(text.provider == "Codex (ChatGPT plan) · default")
        #expect(text.what == "The PDF file (184 KB, 4 pages) will be sent to OpenAI through codex in 1 request (about 20,000 tokens; sent as page images).")
        #expect(text.retention == Sample.codex.retentionNote)
        #expect(text.warnings == ["This PDF is protected, so its text is sent instead of the file"])
        #expect(text.lines == [text.title, text.provider, text.what, text.again, Sample.codex.retentionNote,
                               "This PDF is protected, so its text is sent instead of the file", text.policy])
    }

    @Test func aBlockingReasonIsShownLast() {
        let plan = Sample.plan(pdf: false, requests: 0, tokens: 0, to: "agy", blocking: "The paper does not fit.")
        let text = ShellPlanText.consent(request: ConsentRequest(provider: Sample.antigravity, plan: plan), pageCount: 2, byteCount: 10)
        #expect(text.blockingReason == "The paper does not fit.")
        #expect(text.lines.last == "The paper does not fit.")
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
