import Foundation
import RefereeCore

/// The paper context of discussions, questions and the report (plan.md section 6.3): the same content as a one-pass
/// review (the PDF or the whole text) when it fits within 60% of the job's input budget; otherwise the paper's digest,
/// when the session has one, followed by the rendered pages around the passage (the anchor's page and its two
/// neighbours; for a question without a selection and for the report, page 1 and its neighbour).
struct PaperContext {
    /// The parts before the cache boundary.
    var parts: [LLMPart]
    /// Opens the task after the cache boundary: in PDF mode, how pages are counted.
    var taskPrefix: String
    var mode: Planner.PaperContextMode
    var budget: TokenBudget

    var sendsPDF: Bool { mode == .pdf }

    /// `anchorPage`: the 0-based page of the passage, nil for the whole paper.
    init(paper: LoadedPaper, context: EngineContext, descriptor: ProviderDescriptor, anchorPage: Int?, job: Planning.Job,
         dependencies: EngineDependencies, forceText: Bool) {
        let rendered = dependencies.renderer.render(paper.text, pages: nil)
        let decision = Planner.paperContext(descriptor: descriptor, context: context, paper: paper, rendered: rendered, job: job,
                                            physicalMemoryBytes: dependencies.physicalMemoryBytes, forceText: forceText)
        mode = decision.mode
        budget = decision.budget
        switch decision.mode {
        case .pdf:
            parts = [.pdf(data: paper.data, fileName: PromptBuilder.manuscriptFileName)]
            taskPrefix = PromptBuilder.pdfIntroduction + "\n\n"
        case .fullText:
            parts = [.text(PromptBuilder.fullTextContext(rendered))]
            taskPrefix = ""
        case .excerpt(let maxCharacters):
            let digest = context.paperDigest?.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = max(1_000, maxCharacters - (digest?.count ?? 0) - 600)
            let excerpt = Self.pages(around: anchorPage, of: paper.text, renderer: dependencies.renderer, maxCharacters: room)
            parts = excerpt.text.isEmpty && (digest ?? "").isEmpty
                ? []
                : [.text(PromptBuilder.excerptContext(digest: digest, pages: excerpt.text, firstPage: excerpt.first, lastPage: excerpt.last))]
            taskPrefix = ""
        }
    }

    /// The rendered pages around `pageIndex` (0-based; nil = the start of the paper), as many as fit in `maxCharacters`:
    /// the page and its neighbours, else the page alone, cut at a line break if it is still too long. `first` and `last`
    /// are 1-based page numbers.
    static func pages(around pageIndex: Int?, of text: PaperText, renderer: any PaperRendering,
                      maxCharacters: Int) -> (text: String, first: Int, last: Int) {
        let pages = text.pages
        guard !pages.isEmpty else { return ("", 0, 0) }
        let centre = pageIndex.flatMap { index in pages.firstIndex { $0.index == index } } ?? 0
        var range = pageIndex == nil ? 0..<min(2, pages.count) : max(0, centre - 1)..<min(pages.count, centre + 2)
        var rendered = renderer.render(text, pages: range)
        if rendered.count > maxCharacters, range.count > 1 {
            range = centre..<(centre + 1)
            rendered = renderer.render(text, pages: range)
        }
        if rendered.count > maxCharacters {
            var cut = String(rendered.prefix(maxCharacters))
            if let lastBreak = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: lastBreak) > maxCharacters / 2 {
                cut = String(cut[..<lastBreak])
            }
            rendered = cut
        }
        return (rendered, pages[range.lowerBound].index + 1, pages[range.upperBound - 1].index + 1)
    }
}
