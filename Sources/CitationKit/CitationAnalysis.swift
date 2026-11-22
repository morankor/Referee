import Foundation
import RefereeCore

/// Every stage of building a citation index (plan.md section 8), kept so that tests can look at each one.
struct CitationAnalysis {
    let body: BodyText
    let list: ReferenceList?
    let parsed: [ParsedEntry]
    let entries: [BibEntry]
    let textMentions: [CitationMention]
    let links: LinkMentionFinder.Result
    let index: CitationIndex

    init(paper: PaperText, links rawLinks: [RawLink]) {
        let body = BodyText(paper: paper)
        self.body = body
        // §8.2: no heading, or fewer than three entries -> an empty index; PDFKit still follows links as usual.
        guard let list = BibliographyLocator.locate(in: body) else {
            self.list = nil
            parsed = []
            entries = []
            textMentions = []
            links = LinkMentionFinder.Result(mentions: [], pieces: 0, ignored: 0)
            index = CitationIndex(style: .unknown)
            return
        }
        self.list = list

        // §8.2 step 7 and §8.3: the entries.
        let urlLinks: [(link: RawLink, url: String)] = rawLinks.compactMap { link in
            if case .url(let url) = link.target { return (link, url) }
            return nil
        }
        var parsed: [ParsedEntry] = []
        var entries: [BibEntry] = []
        var extents: [Int: LinkMentionFinder.ListExtent] = [:]
        for (id, entry) in list.entries.enumerated() {
            let lines = entry.lines.map { body.lines[$0] }
            let text = EntryText.join(lines.map(\.text))
            let inside = urlLinks.filter { candidate in lines.contains { CitationAnalysis.lies(candidate.link, inside: $0) } }.map(\.url)
            let entryParse = EntryParser.parse(text, style: list.style, linkURLs: inside)
            parsed.append(entryParse)
            entries.append(BibEntry(id: id, label: entry.label.map(String.init), rawText: text, spans: lines.map(\.span),
                                    firstLineBounds: lines.first?.bounds, parsed: entryParse.reference))
            for line in lines {
                guard let b = line.bounds else { continue }
                let current = extents[line.pageIndex] ?? LinkMentionFinder.ListExtent(bottom: b.y, top: b.y + b.height)
                extents[line.pageIndex] = LinkMentionFinder.ListExtent(bottom: min(current.bottom, b.y), top: max(current.top, b.y + b.height))
            }
        }
        self.parsed = parsed
        self.entries = entries

        // §8.4: the body text before the heading and after the end of the list.
        let flow = FlowText(lines: Array(body.lines[..<list.heading]) + Array(body.lines[list.end...]))
        if list.style == .numeric {
            var idsByLabel: [Int: Int] = [:]
            for (id, entry) in list.entries.enumerated() {
                if let label = entry.label { idsByLabel[label] = id }
            }
            textMentions = TextMentionFinder.numericMentions(in: flow, entryIDsByLabel: idsByLabel)
        } else {
            let candidates: [TextMentionFinder.Candidate] = parsed.enumerated().compactMap { id, entry in
                guard let year = entry.reference.year else { return nil }
                let keys = AuthorKeys.keys(surnames: entry.reference.authorSurnames, truncated: entry.authorsTruncated)
                return keys.isEmpty ? nil : TextMentionFinder.Candidate(id: id, year: year, suffix: entry.reference.yearSuffix, keys: keys)
            }
            textMentions = TextMentionFinder.authorYearMentions(in: flow, candidates: candidates)
        }

        // §8.5: the link path, and the merge of the two. A link on a page the paper does not have is ignored.
        let pages = Set(paper.pages.map(\.index))
        let targets = entries.compactMap { entry in entry.firstLineBounds.map { LinkMentionFinder.Target(id: entry.id, firstLine: $0) } }
        links = LinkMentionFinder.find(links: rawLinks.filter { pages.contains($0.pageIndex) }, style: list.style, targets: targets, extents: extents)
        let mentions = MentionMerger.merge(text: textMentions, links: links.mentions, body: body)
        index = CitationIndex(style: list.style, entries: entries, mentions: mentions, bibliographyHeading: body.lines[list.heading].span)
    }

    /// A link annotation lies inside a line when its centre is within the line's bounds (2 pt of slack: hyperref draws
    /// its rectangles a little larger than the text).
    static func lies(_ link: RawLink, inside line: BodyLine) -> Bool {
        guard link.pageIndex == line.pageIndex, let b = line.bounds else { return false }
        let x = link.bounds.x + link.bounds.width / 2
        let y = link.bounds.y + link.bounds.height / 2
        return x >= b.x - 2 && x <= b.x + b.width + 2 && y >= b.y - 2 && y <= b.y + b.height + 2
    }
}
