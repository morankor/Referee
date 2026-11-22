import Foundation
import RefereeCore

/// One review run (plan.md section 6.6), in the task the stream started for it:
///
///     .started → .phase(.preparing) → for each request: .phase(.reading(part:of:)) or .phase(.wholePaperPass),
///     drafts and comments as the model writes → notices → .digest (read in parts only) → .finished
///
/// The rules applied to each closed block, in this order: a repeat of an existing non-rejected comment (same folded
/// quote and title) is dropped; a third or later `strength` comment is dropped and named in one notice at the end; the
/// quote is anchored; a comment of the same kind on the same passage as an earlier one gets `similarTo`.
final class ReviewJob {
    private let dependencies: EngineDependencies
    private let paper: LoadedPaper
    private let context: EngineContext
    private let sink: JobSink<ReviewEvent>
    private let book: RunBook
    private let categories: CategoryTable
    private let system: String
    private let prior: [ReviewComment]                   // existing comments that are not rejected
    private var accepted: [ReviewComment] = []
    private var seenKeys: Set<String> = []               // folded quote + title of every comment the repeat rule compares with
    private var strengths = 0
    private var droppedStrengths: [String] = []
    private var notices: Set<String> = []
    private var matcher: (any QuoteMatching)?
    private var budget: TokenBudget?
    private var rendered = ""                            // the whole paper as text mode sends it
    private var parser = CommentStreamParser()

    static let maxStrengths = 2
    static let maxContinuations = 2

    init(dependencies: EngineDependencies, paper: LoadedPaper, existing: [ReviewComment], context: EngineContext, sink: JobSink<ReviewEvent>) {
        self.dependencies = dependencies
        self.paper = paper
        self.context = context
        self.sink = sink
        book = RunBook(kind: .review, context: context, dependencies: dependencies)
        categories = CategoryTable(rubric: context.rubric)
        system = PromptBuilder.reviewSystem(context)
        prior = existing.filter { $0.status != .rejected }
        seenKeys = Set(prior.map { Self.repeatKey(quote: $0.anchor.quote, title: $0.title) })
    }

    func run() async {
        sink.send(.started(book.run))
        guard let provider = book.provider else {
            return finish(.failed(book.missingProvider.userMessage))
        }
        sink.send(.phase(.preparing))
        rendered = dependencies.renderer.render(paper.text, pages: nil)
        var plan = Planner.review(descriptor: provider.descriptor, context: context, paper: paper, rendered: rendered,
                                  renderer: dependencies.renderer, physicalMemoryBytes: dependencies.physicalMemoryBytes)
        Log.event("engine.review.planned", ["provider": .id(provider.descriptor.id), "pdf": .bool(plan.sendsPDF),
                                            "requests": .int(plan.sendPlan.requestCount), "blocked": .bool(plan.sendPlan.blockingReason != nil)])
        if let reason = plan.sendPlan.blockingReason { return finish(.failed(reason)) }
        matcher = dependencies.matcherFactory(paper.text)
        if Task.isCancelled { return finish(.cancelled) }

        var fellBackToText = false
        while true {
            do {
                let digest = try await execute(plan)
                endNotices()
                if let digest, !digest.isEmpty { sink.send(.digest(digest)) }
                return finish(.completed)
            } catch JobInterruption.cancelled {
                return finish(.cancelled)
            } catch JobInterruption.failed(let error) {
                if plan.sendsPDF, !fellBackToText, RunBook.isPDFRejection(error) {
                    fellBackToText = true
                    notice("The provider did not accept the PDF file (\(error.userMessage)), so the review was restarted with the text extracted from it.")
                    Log.event("engine.review.textfallback", ["provider": .id(provider.descriptor.id), "error": .id(error.logName)])
                    plan = Planner.review(descriptor: provider.descriptor, context: context, paper: paper, rendered: rendered,
                                          renderer: dependencies.renderer, physicalMemoryBytes: dependencies.physicalMemoryBytes, forceText: true)
                    if let reason = plan.sendPlan.blockingReason { return finish(.failed(reason)) }
                    continue
                }
                endNotices()
                return finish(.failed(error.userMessage))
            } catch {
                return finish(.failed(LLMError.malformedResponse("\(type(of: error))").userMessage))
            }
        }
    }

    // ---- requests ----

    /// Runs every request of the plan; returns the final notes of a review read in parts (nil for one pass).
    private func execute(_ plan: JobPlan) async throws -> String? {
        budget = plan.budget
        if plan.parts.isEmpty {
            sink.send(.phase(.reading(part: 1, of: 1)))
            if plan.sendsPDF {
                let prefix: [LLMPart] = [.pdf(data: paper.data, fileName: PromptBuilder.manuscriptFileName), .cacheBoundary]
                _ = try await chain(prefix: prefix, task: PromptBuilder.pdfModeReviewTask(meta: context.meta, existingTitles: titlesSoFar))
            } else {
                let text = PromptBuilder.textModeReview(paper: rendered, meta: context.meta, existingTitles: titlesSoFar)
                _ = try await chain(prefix: [.text(text.paper), .cacheBoundary], task: text.task)
            }
            return nil
        }
        var notes = ""
        for (position, range) in plan.parts.enumerated() {
            sink.send(.phase(.reading(part: position + 1, of: plan.parts.count)))
            let pages = paper.text.pages
            let task = PromptBuilder.partTask(part: position + 1, of: plan.parts.count, firstPage: pages[range.lowerBound].index + 1,
                                              lastPage: pages[range.upperBound - 1].index + 1, notes: notes,
                                              text: dependencies.renderer.render(paper.text, pages: range))
            if let written = try await chain(prefix: [.text(task)], task: nil), !written.isEmpty {
                notes = Self.capped(notes: written)
            }
        }
        sink.send(.phase(.wholePaperPass))
        _ = try await chain(prefix: [.text(PromptBuilder.wholeTask(notes: notes, titles: titlesSoFar))], task: nil)
        return notes
    }

    /// One request and its continuations (section 6.5): a second and a third request with the same paper context and
    /// `TASK_CONTINUE` when an answer is cut off. Applies the fallbacks when no answer had any structure. Returns the
    /// notes the model wrote after `@@NOTES`, if any.
    private func chain(prefix: [LLMPart], task: String?) async throws -> String? {
        var parts = prefix + (task.map { [LLMPart.text($0)] } ?? [])
        var continuations = 0
        var structured = false
        var raw = ""
        var notes: String?
        while true {
            let answer = try await request(parts)
            structured = structured || answer.structured
            raw += (raw.isEmpty ? "" : "\n") + answer.raw
            if let written = answer.notes, !written.isEmpty { notes = written }
            if answer.stop == .refusal {
                notice("The model declined to continue.")
                break
            }
            guard answer.stop == .maxTokens || (!answer.sawDone && answer.openAtEnd) else { break }
            guard continuations < Self.maxContinuations else {
                notice("The model's answer was cut off; some comments may be missing.")
                break
            }
            continuations += 1
            parts = prefix + [.text(PromptBuilder.continueTask(titles: titlesSoFar))]
        }
        if !structured { await fallback(raw) }
        return notes
    }

    private struct Answer {
        var stop: StopReason
        var sawDone: Bool
        var openAtEnd: Bool
        var structured: Bool
        var notes: String?
        var raw: String
    }

    private func request(_ parts: [LLMPart]) async throws -> Answer {
        let limits = budget?.requestLimits(settings: context.providerSettings)
            ?? (contextWindow: nil, maxOutputTokens: context.providerSettings.maxOutputTokens)
        let request = LLMRequest(model: context.provider.model, system: system, parts: parts, maxOutputTokens: limits.maxOutputTokens,
                                 contextWindow: limits.contextWindow, purpose: .review)
        parser = CommentStreamParser(mode: .review, categories: categories)
        var notes: String?
        let outcome: StreamOutcome
        do {
            outcome = try await book.stream(request, onDelta: { delta in
                notes = await handle(parser.feed(delta)) ?? notes
            }, onStatus: { line in
                notice(line)
            })
        } catch JobInterruption.failed(let error) {
            // Comments so far stay; the open block is closed as it stands (section 6.6).
            _ = await handle(parser.finish())
            throw JobInterruption.failed(error)
        }
        let openAtEnd = parser.hasOpenBlock
        notes = await handle(parser.finish()) ?? notes
        return Answer(stop: outcome.stop, sawDone: parser.sawDone, openAtEnd: openAtEnd,
                      structured: parser.sawAnyBlock || parser.sawDone || parser.sawNotes, notes: notes, raw: parser.rawText)
    }

    /// Turns parser output into events; returns the notes, if the output carried any.
    private func handle(_ outputs: [CommentStreamParser.Output]) async -> String? {
        var notes: String?
        for output in outputs {
            switch output {
            case .draftStarted(let id):
                sink.send(.draft(DraftComment(id: id, body: "")))
            case .draftUpdated(let draft):
                sink.send(.draft(draft))
            case .blockClosed(let draft):
                await accept(draft)
            case .notes(let text):
                notes = text
            case .done:
                break
            }
        }
        return notes
    }

    // ---- fallbacks (section 6.5) ----

    static let emptyAnswerNotice = "The model returned an empty answer."

    private func fallback(_ raw: String) async {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice(Self.emptyAnswerNotice)
            return
        }
        let drafts = ParserFallbacks.jsonComments(in: raw, categories: categories)
        if !drafts.isEmpty {
            Log.event("engine.review.fallback", ["kind": .id("json"), "comments": .int(drafts.count)])
            for draft in drafts { await accept(draft) }
            return
        }
        Log.event("engine.review.fallback", ["kind": .id("unstructured")])
        // Not one of `accepted`: it has no quote for the rules, and its title is no comment to list in a later task.
        let draft = ParserFallbacks.unstructuredDraft(from: raw)
        sink.send(.comment(makeComment(draft, anchor: Anchor(quote: "", confidence: .none, locationLabel: "")), replacesDraft: draft.id))
        notice(ParserFallbacks.unstructuredNotice)
    }

    // ---- the rules of section 6.6 ----

    private func accept(_ draft: DraftComment) async {
        let title = draft.title ?? ""
        let quote = draft.quote ?? ""
        let key = Self.repeatKey(quote: quote, title: title)
        guard !seenKeys.contains(key) else {
            Log.event("engine.review.dropped", ["reason": .id("repeat")])
            return
        }
        let kind = draft.kind ?? .minor
        if kind == .strength {
            guard strengths < Self.maxStrengths else {
                droppedStrengths.append(title)
                Log.event("engine.review.dropped", ["reason": .id("strength-cap")])
                return
            }
            strengths += 1
        }
        var comment = makeComment(draft, anchor: await anchor(quote: quote, page: draft.page))
        comment.similarTo = similarTarget(for: comment)
        seenKeys.insert(key)
        accepted.append(comment)
        sink.send(.comment(comment, replacesDraft: draft.id))
    }

    private func makeComment(_ draft: DraftComment, anchor: Anchor) -> ReviewComment {
        let now = Date()
        return ReviewComment(id: draft.id, origin: .ai(runID: book.run.id), status: .pending, kind: draft.kind ?? .minor,
                             category: draft.category ?? CategoryTable.fallback, title: draft.title ?? "", body: draft.body,
                             suggestion: draft.suggestion, anchor: anchor, includeInReport: true, createdAt: now, updatedAt: now)
    }

    /// Section 6.7, "In the engine": the matcher's spans with their rectangles and label; else the page alone when the
    /// model gave a page this paper has; else nothing. The quote is always kept.
    private func anchor(quote: String, page: Int?) async -> Anchor {
        let pageCount = max(paper.ref.pageCount, paper.text.pages.count)
        let pageIndex = page.flatMap { $0 >= 1 && $0 <= pageCount ? $0 - 1 : nil }
        if !quote.isEmpty, let matcher, let match = matcher.locate(quote: quote, pageHint: pageIndex), let first = match.spans.first {
            let rects = await dependencies.paperService.rects(for: match.spans, in: paper.ref)
            return Anchor(quote: quote, spans: match.spans, rects: rects, pageIndex: first.pageIndex, confidence: match.confidence,
                          locationLabel: matcher.locationLabel(for: match.spans))
        }
        if let pageIndex {
            return Anchor(quote: quote, pageIndex: pageIndex, confidence: .pageOnly, locationLabel: "p. \(pageIndex + 1)")
        }
        return Anchor(quote: quote, confidence: .none, locationLabel: "")
    }

    /// The first earlier comment of the same kind on the same passage: at least 80% of this comment's span characters
    /// lie within its spans. When either has no spans (the matcher found neither quote), the same passage is the same
    /// folded quote.
    private func similarTarget(for comment: ReviewComment) -> UUID? {
        let quote = Folding.fold(comment.anchor.quote)
        for earlier in prior + accepted where earlier.kind == comment.kind && earlier.id != comment.id {
            if !comment.anchor.spans.isEmpty, !earlier.anchor.spans.isEmpty {
                if Self.overlap(comment.anchor.spans, within: earlier.anchor.spans) >= 0.8 { return earlier.id }
            } else if !quote.isEmpty, quote == Folding.fold(earlier.anchor.quote) {
                return earlier.id
            }
        }
        return nil
    }

    /// The share of the characters of `spans` that lie inside `others`.
    static func overlap(_ spans: [TextSpan], within others: [TextSpan]) -> Double {
        let total = spans.reduce(0) { $0 + max(0, $1.range.length) }
        guard total > 0 else { return 0 }
        var shared = 0
        for span in spans {
            for other in others where other.pageIndex == span.pageIndex {
                let lower = max(span.range.location, other.range.location)
                let upper = min(span.range.upperBound, other.range.upperBound)
                shared += max(0, upper - lower)
            }
        }
        return Double(min(shared, total)) / Double(total)
    }

    static func repeatKey(quote: String, title: String) -> String {
        Folding.fold(quote) + "\u{0}" + Folding.fold(title)
    }

    /// Titles of the existing non-rejected comments and of this run's, for the task texts.
    private var titlesSoFar: [String] { (prior + accepted).map(\.title) }

    // ---- notices and the end ----

    /// A user-visible notice, at most once per run for the same text.
    private func notice(_ text: String) {
        guard !text.isEmpty, notices.insert(text).inserted else { return }
        sink.send(.notice(text))
    }

    private func endNotices() {
        guard !droppedStrengths.isEmpty else { return }
        let names = droppedStrengths.map { "“\($0)”" }.joined(separator: "; ")
        let count = droppedStrengths.count
        notice("\(count) further strength comment\(count == 1 ? " was" : "s were") left out, because a review keeps at most "
               + "\(Self.maxStrengths): \(names).")
    }

    private func finish(_ status: RunStatus) {
        sink.finish(final: .finished(book.finished(status)))
    }

    /// Notes carried to the next part are kept within the budget planning reserved for them (section 6.4).
    static func capped(notes: String) -> String {
        guard notes.count > Planning.notesBudgetChars else { return notes }
        let cut = String(notes.prefix(Planning.notesBudgetChars))
        if let lastBreak = cut.lastIndex(where: { $0 == "\n" || $0 == " " }), cut.distance(from: cut.startIndex, to: lastBreak) > Planning.notesBudgetChars / 2 {
            return String(cut[..<lastBreak])
        }
        return cut
    }
}
