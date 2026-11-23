import Foundation
import RefereeCore
import AppCore

/// One row of the facts grid of the consent card and of the destination menu (design review D12, D24): a label and
/// its value, or, when `isWarning`, the warning row (a triangle in place of the label).
struct ShellConsentFact: Equatable {
    var label: String
    var value: String
    var isWarning: Bool = false
}

/// What the destination menu says about a send plan (plan.md section 9.7; D24): the facts grid, then the plan's
/// warnings one per line; a blocking reason replaces both.
struct ShellPlanSummary: Equatable {
    var facts: [ShellConsentFact]
    var warnings: [String]
    var blockingReason: String?
}

/// What the consent card says (plan.md section 9.7; D12), line by line.
struct ShellConsentText: Equatable {
    var title: String                 // "Send this manuscript to Anthropic?"
    var provider: String              // "Anthropic API · example-large"
    var what: String                  // "The PDF file (2.1 MB, 34 pages) will be sent to api.anthropic.com in 1 request (about 153,000 tokens)."
                                      // Not shown as a paragraph since D12: the grid's spoken label, and what the tests read.
    var facts: [ShellConsentFact]     // What, To, Requests, Kept, and the text-only warning row
    var again: String                 // "Later questions, discussions and the report will send it again to the same provider."
    var warnings: [String]            // the plan's warnings, one per line
    var policy: String                // "Check the journal's policy on AI tools before sending a manuscript under review."
    var blockingReason: String?       // shown in red when the plan cannot run
    var sendButton: String            // "Send to Anthropic"

    /// Every line, in the order the card shows them; a fact as "label: value", the warning row as its sentence.
    var lines: [String] {
        [title, provider] + facts.map { $0.isWarning || $0.label.isEmpty ? $0.value : "\($0.label): \($0.value)" } + [again]
            + warnings + [policy] + (blockingReason.map { [$0] } ?? [])
    }
}

/// The words of plan.md section 9.7, built from a `SendPlan` and the provider's descriptor: the facts of the
/// destination menu and of the consent card, the plan sentence, the question before a second review (D20) and what
/// was sent so far (D34). Pure, so that tests pin every sentence.
enum ShellPlanText {
    /// Fixed, and shown whenever a plan sends extracted text, for every provider (section 9.7).
    static let textOnlyWarning = "Extracted text only: equations and tables may reach the model garbled."
    static let sendAgain = "Later questions, discussions and the report will send it again to the same provider."
    static let journalPolicy = "Check the journal's policy on AI tools before sending a manuscript under review."
    static let dontSend = "Don't Send"
    static let nothingSent = "Nothing has been sent yet."

    /// "to api.anthropic.com"; for a subscription CLI, which hands the text to its vendor, "to OpenAI through Codex" (D12).
    static func destinationPhrase(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        if descriptor.authMode == .subscriptionCLI { return "to \(descriptor.vendor) through \(ShellDestination.shortName(descriptor))" }
        return "to \(host(plan: plan, descriptor: descriptor))"
    }

    /// The address the plan names, else the descriptor's.
    static func host(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        plan.destination.isEmpty ? descriptor.destination : plan.destination
    }

    /// "A review will send the PDF file in 1 request, about 153,000 tokens, to api.anthropic.com." with the delivery
    /// note in brackets before the full stop when the descriptor has one ("… through Codex (sent as page images).").
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

    // ---- the facts (D12, D24) ----

    /// "The PDF file · 165 KB · 4 pages" or "Extracted text of 4 pages".
    static func whatIsSent(plan: SendPlan, pageCount: Int, byteCount: Int) -> String {
        let pages = ShellFormat.count(pageCount, "page", "pages")
        return plan.sendsPDF ? "The PDF file · \(ShellFormat.bytes(byteCount)) · \(pages)" : "Extracted text of \(pages)"
    }

    /// The host ("api.anthropic.com"), or for a subscription CLI "Anthropic, through Claude Code".
    static func recipient(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        if descriptor.authMode == .subscriptionCLI { return "\(descriptor.vendor), through \(ShellDestination.shortName(descriptor))" }
        return host(plan: plan, descriptor: descriptor)
    }

    /// "1 · about 18,000 tokens", and " · sent as page images" when the descriptor says how the PDF goes.
    static func requests(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        var value = "\(ShellFormat.grouped(plan.requestCount)) · about \(ShellFormat.approximately(plan.estimatedInputTokens)) tokens"
        if plan.sendsPDF, let note = descriptor.pdfDeliveryNote, !note.isEmpty { value += " · " + note }
        return value
    }

    /// The facts of a plan: `whatLabel` ("What" on the consent card, "Sends" in the menu), "To", "Requests", "Kept" when
    /// `kept` is given, and the warning row when the plan sends extracted text.
    static func facts(plan: SendPlan, descriptor: ProviderDescriptor, pageCount: Int, byteCount: Int, whatLabel: String,
                      kept: String?) -> [ShellConsentFact] {
        var facts = [ShellConsentFact(label: whatLabel, value: whatIsSent(plan: plan, pageCount: pageCount, byteCount: byteCount)),
                     ShellConsentFact(label: "To", value: recipient(plan: plan, descriptor: descriptor)),
                     ShellConsentFact(label: "Requests", value: requests(plan: plan, descriptor: descriptor))]
        if let kept, !kept.isEmpty { facts.append(ShellConsentFact(label: "Kept", value: kept)) }
        if !plan.sendsPDF { facts.append(ShellConsentFact(label: "", value: textOnlyWarning, isWarning: true)) }
        return facts
    }

    /// The destination menu (D24): "Sends", "To", "Requests" and the warning row, then the plan's warnings; a blocking
    /// reason replaces all of it. The retention note goes under it, from the descriptor.
    static func menuSummary(plan: SendPlan, descriptor: ProviderDescriptor, pageCount: Int, byteCount: Int) -> ShellPlanSummary {
        if let blocking = plan.blockingReason, !blocking.isEmpty { return ShellPlanSummary(facts: [], warnings: [], blockingReason: blocking) }
        return ShellPlanSummary(facts: facts(plan: plan, descriptor: descriptor, pageCount: pageCount, byteCount: byteCount, whatLabel: "Sends",
                                             kept: nil),
                                warnings: plan.warnings.filter { !$0.isEmpty }, blockingReason: nil)
    }

    /// The consent card for `request`, about a document of `pageCount` pages and `byteCount` bytes. "Kept" is the
    /// provider's retention note, for every remote provider (the card is only ever shown for one).
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
            facts: facts(plan: plan, descriptor: descriptor, pageCount: pageCount, byteCount: byteCount, whatLabel: "What",
                         kept: descriptor.isLocal ? nil : descriptor.retentionNote),
            again: sendAgain,
            warnings: plan.warnings.filter { !$0.isEmpty },
            policy: journalPolicy,
            blockingReason: plan.blockingReason.flatMap { $0.isEmpty ? nil : $0 },
            sendButton: "Send to \(descriptor.vendor)")
    }

    // ---- a second review (D20) ----

    static let reviewAgainTitle = "Review this paper again?"
    /// Every comment stays, whatever the provider: the session keeps them across reviews (the user's request at step 5b,
    /// which replaces the review's "comments you have decided stay as they are").
    static let nothingRemoved = "New comments are added next to the existing ones; nothing is removed."

    /// "The model reads the paper again: about 18,000 tokens to Anthropic through Claude Code. New comments are added
    /// next to the existing ones; nothing is removed."
    static func reviewAgain(plan: SendPlan, descriptor: ProviderDescriptor) -> String {
        "The model reads the paper again: about \(ShellFormat.approximately(plan.estimatedInputTokens)) tokens "
            + "\(destinationPhrase(plan: plan, descriptor: descriptor)). " + nothingRemoved
    }

    // ---- what was sent so far (D34) ----

    /// One line per provider of `runs`, the most recently used first: "Mock: 2 times, last 18 Nov 2026 at 11:20
    /// (extracted text)", "(PDF file)", or "(PDF file and extracted text)" when both went. `name` gives a provider's
    /// display name (its id when it is not known); `date` writes the date of the last send. A run still under way
    /// (recorded since step 5c when it starts, status `.running`) is left out until it ends: only then does its record
    /// say whether the PDF or the text went.
    static func sentSoFar(_ runs: [RunRecord], name: (ProviderID) -> String, date: (Date) -> String) -> [String] {
        var order: [ProviderID] = []
        var byProvider: [ProviderID: [RunRecord]] = [:]
        for run in runs where run.status != .running {
            if byProvider[run.provider.providerID] == nil { order.append(run.provider.providerID) }
            byProvider[run.provider.providerID, default: []].append(run)
        }
        let rows = order.compactMap { id -> (last: Date, line: String)? in
            guard let sends = byProvider[id], let last = sends.map(\.startedAt).max() else { return nil }
            let pdf = sends.contains { $0.sentPDF }
            let text = sends.contains { !$0.sentPDF }
            let how = pdf && text ? "PDF file and extracted text" : pdf ? "PDF file" : "extracted text"
            return (last, "\(name(id)): \(ShellFormat.count(sends.count, "time", "times")), last \(date(last)) (\(how))")
        }
        return rows.sorted { $0.last > $1.last }.map(\.line)
    }
}
