import Foundation
import RefereeCore
import AppCore

/// One line of the destination menu's description of a send plan (plan.md section 9.7).
struct ShellPlanLine: Equatable {
    enum Style: Equatable { case normal, warning, blocking }
    var text: String
    var style: Style
}

/// What the consent card says (plan.md section 9.7), line by line.
struct ShellConsentText: Equatable {
    var title: String                 // "Send this manuscript to Anthropic?"
    var provider: String              // "Anthropic API · example-large"
    var what: String                  // "The PDF file (2.1 MB, 34 pages) will be sent to api.anthropic.com in 1 request (about 153,000 tokens)."
    var again: String                 // "Later questions, discussions and the report will send it again to the same provider."
    var retention: String?            // a subscription CLI: what section 12.5 says about it (`retentionNote`)
    var warnings: [String]            // the plan's warnings, one per line
    var policy: String                // "Check the journal's policy on AI tools before sending a manuscript under review."
    var blockingReason: String?       // shown in red when the plan cannot run

    /// Every line, in the order the card shows them.
    var lines: [String] {
        [title, provider, what, again] + (retention.map { [$0] } ?? []) + warnings + [policy] + (blockingReason.map { [$0] } ?? [])
    }
}

/// The words of plan.md section 9.7, built from a `SendPlan` and the provider's descriptor: the plan sentence of the
/// destination menu and the text of the consent card. Pure, so that tests pin every sentence.
enum ShellPlanText {
    /// Fixed, and shown whenever a plan sends extracted text, for every provider (section 9.7).
    static let textOnlyWarning = "Extracted text only: equations and tables may reach the model garbled."
    static let sendAgain = "Later questions, discussions and the report will send it again to the same provider."
    static let journalPolicy = "Check the journal's policy on AI tools before sending a manuscript under review."

    /// "to api.anthropic.com"; for a subscription CLI, which hands the text to its vendor, "to OpenAI through codex".
    static func destinationPhrase(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        let destination = plan.destination.isEmpty ? descriptor.destination : plan.destination
        if descriptor.authMode == .subscriptionCLI { return "to \(descriptor.vendor) through \(destination)" }
        return "to \(destination)"
    }

    /// "A review will send the PDF file in 1 request, about 153,000 tokens, to api.anthropic.com." with the delivery
    /// note in brackets before the full stop when the descriptor has one ("… through codex (sent as page images).").
    /// In text mode: "A review will send the extracted text in 3 requests, about 61,000 tokens, to 127.0.0.1:11434.
    /// Extracted text only: equations and tables may reach the model garbled."
    static func sentence(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        let what = plan.sendsPDF ? "the PDF file" : "the extracted text"
        var sentence = "A review will send \(what) in \(ShellFormat.count(plan.requestCount, "request", "requests")), "
            + "about \(ShellFormat.approximately(plan.estimatedInputTokens)) tokens, \(destinationPhrase(plan: plan, descriptor: descriptor))"
        if plan.sendsPDF, let note = descriptor.pdfDeliveryNote, !note.isEmpty { sentence += " (\(note))" }
        sentence += "."
        if !plan.sendsPDF { sentence += " " + textOnlyWarning }
        return sentence
    }

    /// The destination menu: the sentence, then each warning on a line of its own; a blocking reason replaces all of it.
    static func menuLines(plan: SendPlan, descriptor: ProviderDescriptor) -> [ShellPlanLine] {
        if let blocking = plan.blockingReason, !blocking.isEmpty { return [ShellPlanLine(text: blocking, style: .blocking)] }
        return [ShellPlanLine(text: sentence(plan: plan, descriptor: descriptor), style: .normal)]
            + plan.warnings.filter { !$0.isEmpty }.map { ShellPlanLine(text: $0, style: .warning) }
    }

    /// The consent card for `request`, about a document of `pageCount` pages and `byteCount` bytes.
    static func consent(request: ConsentRequest, pageCount: Int, byteCount: Int) -> ShellConsentText {
        let plan = request.plan
        let descriptor = request.provider
        let pages = ShellFormat.count(pageCount, "page", "pages")
        let requests = ShellFormat.count(plan.requestCount, "request", "requests")
        let tokens = "about \(ShellFormat.approximately(plan.estimatedInputTokens)) tokens"
        let destination = destinationPhrase(plan: plan, descriptor: descriptor)
        let what: String
        if plan.sendsPDF {
            let note = descriptor.pdfDeliveryNote.flatMap { $0.isEmpty ? nil : "; " + $0 } ?? ""
            what = "The PDF file (\(ShellFormat.bytes(byteCount)), \(pages)) will be sent \(destination) in \(requests) (\(tokens)\(note))."
        } else {
            what = "The extracted text (\(pages)) will be sent \(destination) in \(requests) (\(tokens)). \(textOnlyWarning)"
        }
        let model = request.model.flatMap { $0.isEmpty ? nil : $0 } ?? (descriptor.authMode == .subscriptionCLI ? "default" : nil)
        return ShellConsentText(
            title: "Send this manuscript to \(descriptor.vendor)?",
            provider: [descriptor.displayName, model].compactMap { $0 }.joined(separator: " · "),
            what: what,
            again: sendAgain,
            retention: descriptor.authMode == .subscriptionCLI && !descriptor.retentionNote.isEmpty ? descriptor.retentionNote : nil,
            warnings: plan.warnings.filter { !$0.isEmpty },
            policy: journalPolicy,
            blockingReason: plan.blockingReason.flatMap { $0.isEmpty ? nil : $0 })
    }
}
