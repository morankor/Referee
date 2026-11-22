import Foundation
import PDFKit
import RefereeCore
import Composition
import PDFBridge
import PaperText

/// The eight subcommands of plan.md section 10.2, on the same graph the app uses (`LiveDependencies.make`).
struct Commands {
    let options: CLIOptions
    let environment: [String: String]
    /// Set while a review or a question runs, so that Ctrl-C can cancel it (the engine then kills a CLI provider's
    /// process tree; see main.swift).
    let running: RunningTask

    struct Failure: Error {
        let code: Int32
        let message: String
    }

    func run() async throws -> Int32 {
        switch options.command {
        case "dump-raw": return try dumpRaw()
        case "providers": return try await providers()
        case "extract": return try await extract()
        case "anchor": return try await anchor()
        case "citations": return try await citations()
        case "plan": return try await plan()
        case "review": return try await review()
        case "ask": return try await ask()
        default: throw CLIOptions.UsageError(message: "unknown command \(options.command)")
        }
    }

    // ---- shared ----

    private func dependencies() async -> AppDependencies {
        await LiveDependencies.make(environment: environment)
    }

    private func loadPaper(_ dependencies: AppDependencies) async throws -> LoadedPaper {
        let url = URL(fileURLWithPath: options.pdfPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(code: 1, message: "no such file: \(options.pdfPath)") }
        do {
            return try await dependencies.paperService.load(url: url)
        } catch let error as any RefereeError {
            throw Failure(code: 1, message: error.userMessage)
        }
    }

    private func provider(_ dependencies: AppDependencies) throws -> any LLMProvider {
        let id = try options.required("--provider")
        guard let provider = dependencies.providers.provider(id: id) else {
            let known = dependencies.providers.all.map(\.descriptor.id).joined(separator: ", ")
            throw CLIOptions.UsageError(message: "no provider \(id); known: \(known), mock")
        }
        return provider
    }

    /// Exit 3 unless the provider says it is ready (no tokens are spent: section 5.1).
    private func requireReady(_ provider: any LLMProvider) async throws {
        switch await provider.availability() {
        case .ready:
            return
        case .needsSetup(let reason, let hint):
            throw Failure(code: 3, message: "\(provider.descriptor.id) is not set up: \(reason). \(hint)")
        case .unavailable(let reason):
            throw Failure(code: 3, message: "\(provider.descriptor.id) is not available: \(reason)")
        }
    }

    /// The context the app would build (sections 6.1 and 10.2): the provider's settings with the command line's
    /// choices, and the chosen model's entry in the provider's list (`listModels()`), so that planning uses its real
    /// window. "phi4" finds "phi4:latest". Without --model a provider that lists models gets its first, as the Settings
    /// pane preselects it; a subscription CLI keeps its own default.
    private func context(for provider: any LLMProvider, paper: LoadedPaper, dependencies: AppDependencies) async throws -> EngineContext {
        let id = provider.descriptor.id
        let settings = await dependencies.settings.load()
        var providerSettings = settings.providers[id] ?? ProviderSettings(enabled: true, inputMode: .auto)
        providerSettings.enabled = true
        if let mode = options.value("--mode") {
            guard let inputMode = InputMode(rawValue: mode) else { throw CLIOptions.UsageError(message: "--mode must be auto, text or pdf") }
            providerSettings.inputMode = inputMode
        }
        if let window = options.value("--context") {
            guard let tokens = Int(window), tokens > 0 else { throw CLIOptions.UsageError(message: "--context must be a number of tokens") }
            providerSettings.contextWindowOverride = tokens
        }
        let models: [ModelInfo]
        do {
            models = try await provider.listModels()
        } catch {
            Output.note("note: the model list of \(id) could not be read (\(Self.message(error))); planning assumes default limits")
            models = []
        }
        var modelID = options.value("--model") ?? providerSettings.model
        var info: ModelInfo?
        if let wanted = modelID {
            info = models.first { $0.id == wanted } ?? (wanted.contains(":") ? nil : models.first { $0.id == wanted + ":latest" })
            if let info {
                modelID = info.id
            } else if !models.isEmpty {
                Output.note("note: \(wanted) is not in the model list of \(id); planning assumes default limits")
            }
        } else if provider.descriptor.authMode != .subscriptionCLI, let first = models.first {
            info = first
            modelID = first.id
        }
        providerSettings.model = modelID
        return EngineContext(provider: ProviderRef(providerID: id, model: modelID), providerSettings: providerSettings, model: info,
                             prompts: settings.prompts, rubric: settings.rubric,
                             meta: ManuscriptMeta(title: paper.text.titleGuess, reviewerNotes: ""))
    }

    private static func message(_ error: Error) -> String {
        (error as? any RefereeError)?.userMessage ?? "\(type(of: error))"
    }

    // ---- dump-raw ----

    private func dumpRaw() throws -> Int32 {
        guard let document = PDFDocument(url: URL(fileURLWithPath: options.pdfPath)) else {
            throw Failure(code: 1, message: "this file could not be opened as a PDF")
        }
        if document.isLocked { throw Failure(code: 1, message: "this PDF is password-protected") }
        try Output.json(RawExtractor.extract(from: document))          // the format of Fixtures/raw (section 3.6)
        return 0
    }

    // ---- providers ----

    private func providers() async throws -> Int32 {
        let all = (await dependencies()).providers.all
        let statuses = await withTaskGroup(of: (Int, ProviderAvailability).self) { group in
            for (index, provider) in all.enumerated() { group.addTask { (index, await provider.availability()) } }
            var results: [Int: ProviderAvailability] = [:]
            for await (index, status) in group { results[index] = status }
            return results
        }
        var rows: [[String: Any]] = []
        for (index, provider) in all.enumerated() {
            let descriptor = provider.descriptor
            var row: [String: Any] = ["id": descriptor.id, "displayName": descriptor.displayName, "vendor": descriptor.vendor,
                                      "authMode": descriptor.authMode.rawValue, "isLocal": descriptor.isLocal, "destination": descriptor.destination,
                                      "supportsNativePDF": descriptor.supportsNativePDF, "isExperimental": descriptor.isExperimental,
                                      "streaming": descriptor.streaming.rawValue]
            if let note = descriptor.pdfDeliveryNote { row["pdfDeliveryNote"] = note }
            if let limit = descriptor.maxPromptBytes { row["maxPromptBytes"] = limit }
            let text: String
            switch statuses[index] ?? .unavailable(reason: "no answer") {
            case .ready(let detail):
                row["status"] = "ready"; row["detail"] = detail
                text = "ready        \(detail)"
            case .needsSetup(let reason, let hint):
                row["status"] = "needsSetup"; row["reason"] = reason; row["hint"] = hint
                text = "needs setup  \(reason) (\(hint))"
            case .unavailable(let reason):
                row["status"] = "unavailable"; row["reason"] = reason
                text = "unavailable  \(reason)"
            }
            rows.append(row)
            if !options.flag("--json") { Output.line(descriptor.id.padding(toLength: 17, withPad: " ", startingAt: 0) + text) }
        }
        if options.flag("--json") {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            Output.line(String(decoding: data, as: UTF8.self))
        }
        return 0
    }

    // ---- extract ----

    private func extract() async throws -> Int32 {
        let dependencies = await dependencies()
        let paper = try await loadPaper(dependencies)
        let text = paper.text
        if options.flag("--stats") {
            printStats(text)
        } else {
            let pages = try options.value("--pages").map { try CLIOptions.pageRange($0, pageCount: text.pages.count) }
            Output.raw(PaperRenderer().render(text, pages: pages))
        }
        await dependencies.paperService.unload(paper.ref)
        return 0
    }

    /// Per page: the kinds of its lines, the range of its margin numbers and how many lines got a number in step 6 of
    /// section 7.2 (a body line with a number and nothing stripped); then one summary line.
    private func printStats(_ text: PaperText) {
        var ranges: [ClosedRange<Int>] = []
        for page in text.pages {
            var kinds: [LineKind: Int] = [:]
            for line in page.lines { kinds[line.kind, default: 0] += 1 }
            let order: [LineKind] = [.body, .marginNumberOnly, .pageNumber, .runningHeader, .runningFooter, .watermark, .empty]
            let counts = order.map { "\($0.rawValue) \(kinds[$0] ?? 0)" }.joined(separator: ", ")
            let chained = page.lines.filter { $0.marginNumber != nil && ($0.kind == .marginNumberOnly || $0.contentRange != $0.range) }
                .compactMap(\.marginNumber)
            let stepSix = page.lines.filter { $0.kind == .body && $0.marginNumber != nil && $0.contentRange == $0.range }.count
            var line = "page \(page.index + 1): \(page.lines.count) lines: \(counts)"
            if let low = chained.min(), let high = chained.max() {
                ranges.append(low...high)
                line += "; margin numbers \(low)–\(high)"
            } else {
                line += "; no margin numbers"
            }
            line += "; numbered in step 6: \(stepSix)"
            Output.line(line)
        }
        Output.line("text layer: \(text.hasTextLayer ? "yes" : "no"); title guess: \(text.titleGuess.map { "\"\($0)\"" } ?? "none")")
        guard text.hasMarginLineNumbers, let low = ranges.map(\.lowerBound).min(), let high = ranges.map(\.upperBound).max() else {
            Output.line("no margin line numbers")
            return
        }
        // A ruler restarts on every page (ScholarOne); line numbers run on through the document (lineno).
        if ranges.count >= 2, Set(ranges).count == 1 {
            Output.line("ruler \(low)–\(high) on \(ranges.count) pages")
        } else {
            Output.line("margin numbers \(low)–\(high) on \(ranges.count) pages")
        }
    }

    // ---- anchor ----

    private func anchor() async throws -> Int32 {
        let quote = try options.required("--quote")
        var hint: Int?
        if let page = options.value("--page") {
            guard let number = Int(page), number >= 1 else { throw CLIOptions.UsageError(message: "--page must be a page number, 1 or more") }
            hint = number - 1
        }
        let dependencies = await dependencies()
        let paper = try await loadPaper(dependencies)
        defer { Task { await dependencies.paperService.unload(paper.ref) } }
        let matcher = dependencies.matcherFactory(paper.text)
        guard let match = matcher.locate(quote: quote, pageHint: hint) else {
            if options.flag("--json") { Output.jsonLine(["found": false]) } else { Output.line("not found") }
            return 1
        }
        let label = matcher.locationLabel(for: match.spans)
        let rects = await dependencies.paperService.rects(for: match.spans, in: paper.ref)
        if options.flag("--json") {
            var object: [String: Any] = ["found": true, "label": label, "spans": Output.object(match.spans), "rects": Output.object(rects)]
            switch match.confidence {
            case .fuzzy(let score): object["confidence"] = "fuzzy"; object["score"] = score
            default: object["confidence"] = Output.confidence(match.confidence)
            }
            Output.jsonLine(object)
        } else {
            Output.line("\(Output.confidence(match.confidence))  \(label)  (\(match.spans.count) line\(match.spans.count == 1 ? "" : "s"))")
        }
        return 0
    }

    // ---- citations ----

    private func citations() async throws -> Int32 {
        let dependencies = await dependencies()
        let paper = try await loadPaper(dependencies)
        var index = dependencies.citationIndexer.buildIndex(paper: paper.text, links: paper.links)
        // As the model does (section 8.4): rectangles for the mentions that have none, the text-pattern ones.
        for position in index.mentions.indices where index.mentions[position].rects.isEmpty && !index.mentions[position].spans.isEmpty {
            index.mentions[position].rects = await dependencies.paperService.rects(for: index.mentions[position].spans, in: paper.ref)
        }
        await dependencies.paperService.unload(paper.ref)
        if options.flag("--json") {
            try Output.json(index)
            return 0
        }
        let fromText = index.mentions.filter { $0.source == .textPattern }.count
        let fromLinks = index.mentions.count - fromText
        Output.line("style \(index.style.rawValue); \(index.entries.count) entries; \(index.mentions.count) mentions: "
                    + "\(fromText) from text patterns, \(fromLinks) from link annotations")
        for entry in index.entries {
            let authors = entry.parsed.authorSurnames.joined(separator: ", ")
            let year = entry.parsed.year.map { " \($0)\(entry.parsed.yearSuffix ?? "")" } ?? ""
            let label = entry.label.map { "[\($0)] " } ?? ""
            Output.line("entry \(entry.id): \(label)\(authors)\(year)" + (entry.parsed.title.map { " · \($0)" } ?? ""))
        }
        for mention in index.mentions {
            let targets = mention.entryIDs.map(String.init).joined(separator: ", ")
            Output.line("mention \(mention.id), p. \(mention.pageIndex + 1): \"\(mention.text)\" → \(targets.isEmpty ? "none" : targets) "
                        + "(\(mention.source == .textPattern ? "text" : "link"), \(mention.rects.count) rect\(mention.rects.count == 1 ? "" : "s"))")
        }
        return 0
    }

    // ---- plan ----

    private func plan() async throws -> Int32 {
        let dependencies = await dependencies()
        let provider = try provider(dependencies)
        let paper = try await loadPaper(dependencies)
        let context = try await context(for: provider, paper: paper, dependencies: dependencies)
        let plan = await dependencies.engine.plan(paper: paper, context: context)
        await dependencies.paperService.unload(paper.ref)
        Output.line("PLAN sendsPDF=\(plan.sendsPDF) requests=\(plan.requestCount) estimatedInputTokens=\(plan.estimatedInputTokens) "
                    + "destination=\(plan.destination) local=\(plan.isLocal) model=\(context.provider.model ?? "default") "
                    + "contextWindow=\(context.model?.contextWindow.map(String.init) ?? "unknown")")
        for warning in plan.warnings { Output.line("warning: \(warning)") }
        if let reason = plan.blockingReason {
            Output.line("blocked: \(reason)")
            return 1
        }
        return 0
    }

    // ---- review ----

    private struct Tally {
        var comments = 0, anchored = 0, pageOnly = 0, unanchored = 0, similar = 0
    }

    private func review() async throws -> Int32 {
        let json = options.flag("--json")
        let dependencies = await dependencies()
        let provider = try provider(dependencies)
        try await requireReady(provider)
        let paper = try await loadPaper(dependencies)
        let context = try await context(for: provider, paper: paper, dependencies: dependencies)
        let plan = await dependencies.engine.plan(paper: paper, context: context)
        if let reason = plan.blockingReason { throw Failure(code: 1, message: reason) }
        // Choosing a provider on the command line is the consent (section 10.2); one line says where the paper goes.
        Output.note("sending \(plan.sendsPDF ? "PDF" : "text") to \(plan.destination)"
                    + (plan.requestCount > 1 ? " in \(plan.requestCount) requests" : ""))
        let start = ContinuousClock.now
        let engine = dependencies.engine
        let events = Task { () -> (tally: Tally, run: RunRecord?) in
            var tally = Tally()
            var finished: RunRecord?
            do {
                for try await event in engine.review(paper: paper, existing: [], context: context) {
                    if json { Self.printJSON(event) }
                    switch event {
                    case .comment(let comment, _):
                        tally.comments += 1
                        switch comment.anchor.confidence {
                        case .exact, .fuzzy: tally.anchored += 1
                        case .pageOnly: tally.pageOnly += 1
                        case .none: tally.unanchored += 1
                        }
                        if comment.similarTo != nil { tally.similar += 1 }
                        if !json { Self.printComment(comment) }
                    case .phase(let phase):
                        if !json { Output.note(Self.describe(phase)) }
                    case .notice(let text):
                        if !json { Output.note("notice: \(text)") }
                    case .digest(let notes):
                        if !json { Output.note("notes for later requests: \(notes.count) characters") }
                    case .finished(let run):
                        finished = run
                    case .started, .draft:
                        break
                    }
                }
            } catch {
                Output.note("error: \(Self.message(error))")
            }
            return (tally, finished)
        }
        running.set { events.cancel() }
        let (tally, run) = await events.value
        running.set(nil)
        await dependencies.paperService.unload(paper.ref)
        let status = run?.status ?? .cancelled                         // a stream without .finished was cancelled (Appendix A.6)
        if case .failed(let message) = status { Output.note("error: \(message)") }
        let summary = "SUMMARY comments=\(tally.comments) anchored=\(tally.anchored) pageOnly=\(tally.pageOnly) unanchored=\(tally.unanchored) "
            + "similar=\(tally.similar) requests=\(run?.requestCount ?? 0) status=\(Output.status(status)) seconds=\(Output.seconds(since: start))"
        if json {
            Output.jsonLine(["event": "summary", "comments": tally.comments, "anchored": tally.anchored, "pageOnly": tally.pageOnly,
                             "unanchored": tally.unanchored, "similar": tally.similar, "requests": run?.requestCount ?? 0,
                             "status": Output.status(status), "seconds": Double(Output.seconds(since: start)) ?? 0])
        } else {
            Output.line(summary)
        }
        return status == .completed ? 0 : 1
    }

    /// "[major] p. 1, lines 13–14 (exact)  Title", then the body, the suggestion and a blank line (section 10.2).
    private static func printComment(_ comment: ReviewComment) {
        let label = comment.anchor.locationLabel.isEmpty ? "" : comment.anchor.locationLabel + " "
        Output.line("[\(comment.kind.rawValue)] \(label)(\(Output.confidence(comment.anchor.confidence)))  \(comment.title)")
        Output.line(comment.body)
        if let suggestion = comment.suggestion { Output.line("Suggestion: \(suggestion)") }
        Output.line("")
    }

    private static func describe(_ phase: ReviewPhase) -> String {
        switch phase {
        case .preparing: return "preparing"
        case .reading(let part, let count): return "reading part \(part) of \(count)"
        case .wholePaperPass: return "reading the whole paper once more"
        }
    }

    private static func printJSON(_ event: ReviewEvent) {
        switch event {
        case .started(let run): Output.jsonLine(["event": "started", "run": Output.object(run)])
        case .phase(let phase): Output.jsonLine(["event": "phase", "phase": describe(phase)])
        case .draft(let draft): Output.jsonLine(["event": "draft", "id": draft.id.uuidString, "title": draft.title ?? NSNull()])
        case .comment(let comment, let draft):
            Output.jsonLine(["event": "comment", "replacesDraft": draft.uuidString, "comment": Output.object(comment)])
        case .notice(let text): Output.jsonLine(["event": "notice", "text": text])
        case .digest(let notes): Output.jsonLine(["event": "digest", "text": notes])
        case .finished(let run): Output.jsonLine(["event": "finished", "run": Output.object(run)])
        }
    }

    // ---- ask ----

    private func ask() async throws -> Int32 {
        let question = try options.required("--question")
        let dependencies = await dependencies()
        let provider = try provider(dependencies)
        try await requireReady(provider)
        let paper = try await loadPaper(dependencies)
        let context = try await context(for: provider, paper: paper, dependencies: dependencies)
        // The selected passage, as the model builds it from a selection (section 6.9): located with the matcher.
        var anchor: Anchor?
        if let quote = options.value("--quote") {
            let matcher = dependencies.matcherFactory(paper.text)
            if let match = matcher.locate(quote: quote, pageHint: nil), let first = match.spans.first {
                anchor = Anchor(quote: quote, spans: match.spans, rects: await dependencies.paperService.rects(for: match.spans, in: paper.ref),
                                pageIndex: first.pageIndex, confidence: match.confidence, locationLabel: matcher.locationLabel(for: match.spans))
            } else {
                Output.note("note: the quote was not found in the paper; it is sent as given")
                anchor = Anchor(quote: quote, confidence: .none, locationLabel: "")
            }
        }
        let plan = await dependencies.engine.plan(paper: paper, context: context)
        Output.note("sending \(plan.sendsPDF ? "PDF" : "text") to \(plan.destination)")
        let conversation = Conversation(id: UUID(), anchor: anchor, createdAt: Date())
        let engine = dependencies.engine
        let replies = Task { () -> (text: String, run: RunRecord?) in
            var text = ""
            var finished: RunRecord?
            do {
                for try await event in engine.ask(paper: paper, conversation: conversation, question: question, context: context) {
                    switch event {
                    case .textDelta(let delta):
                        text += delta
                        Output.raw(delta)
                    case .notice(let notice): Output.note("notice: \(notice)")
                    case .finished(_, _, let run): finished = run
                    case .started: break
                    }
                }
            } catch {
                Output.note("error: \(Self.message(error))")
            }
            return (text, finished)
        }
        running.set { replies.cancel() }
        let (text, run) = await replies.value
        running.set(nil)
        await dependencies.paperService.unload(paper.ref)
        Output.raw(text.hasSuffix("\n") ? "" : "\n")
        let status = run?.status ?? .cancelled
        if case .failed(let message) = status { Output.note("error: \(message)") }
        return status == .completed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
    }
}

/// The job Ctrl-C cancels.
final class RunningTask: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (@Sendable () -> Void)?
    func set(_ cancel: (@Sendable () -> Void)?) { lock.withLock { self.cancel = cancel } }
    func cancelIfRunning() -> Bool {
        guard let cancel = lock.withLock({ self.cancel }) else { return false }
        cancel()
        return true
    }
}
