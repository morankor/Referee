import Foundation
import RefereeCore

/// Merges the mentions of the two paths (plan.md section 8.5): per page and per entry, the k-th link mention of that
/// entry is paired with the k-th text mention that lists it as a candidate. A pair becomes one mention with the link's
/// target and rectangles and the text mention's text and spans (source `.linkAnnotation`, since its target came from
/// the link). Unpaired mentions of either kind are kept. The result is sorted by page and position, ids 0…n−1.
enum MentionMerger {
    static func merge(text textMentions: [CitationMention], links linkMentions: [CitationMention], body: BodyText) -> [CitationMention] {
        let texts = ordered(textMentions, body: body)
        let links = ordered(linkMentions, body: body)

        var pairedText = Array(repeating: false, count: texts.count)
        var partner: [Int: Int] = [:]                       // link index -> text index
        var groups: [PageEntry: [Int]] = [:]
        for (i, link) in links.enumerated() {
            guard let entry = link.entryIDs.first else { continue }
            groups[PageEntry(page: link.pageIndex, entry: entry), default: []].append(i)
        }
        for key in groups.keys.sorted(by: { ($0.page, $0.entry) < ($1.page, $1.entry) }) {
            let candidates = texts.indices.filter { !pairedText[$0] && texts[$0].pageIndex == key.page && texts[$0].entryIDs.contains(key.entry) }
            for (link, text) in zip(groups[key] ?? [], candidates) {
                partner[link] = text
                pairedText[text] = true
            }
        }

        var result: [CitationMention] = []
        for (i, link) in links.enumerated() {
            if let t = partner[i] {
                let text = texts[t]
                result.append(CitationMention(id: 0, pageIndex: text.pageIndex, text: text.text, spans: text.spans, rects: link.rects,
                                              entryIDs: link.entryIDs, source: .linkAnnotation))
            } else {
                result.append(link)
            }
        }
        for (i, text) in texts.enumerated() where !pairedText[i] { result.append(text) }

        result = ordered(result, body: body)
        for i in result.indices { result[i].id = i }
        return result
    }

    private struct PageEntry: Hashable {
        var page: Int
        var entry: Int
    }

    /// Sorted by page, then by text offset: the first span's when the mention has spans, else an estimate from its first
    /// rectangle (the line under it); then top to bottom, left to right; ties keep their order.
    static func ordered(_ mentions: [CitationMention], body: BodyText) -> [CitationMention] {
        let keyed = mentions.enumerated().map { (index, mention) -> (key: SortKey, mention: CitationMention) in
            let rect = mention.rects.first
            var offset = Double.infinity
            if let span = mention.spans.first {
                offset = Double(span.range.location)
            } else if let r = rect, let estimate = body.estimatedOffset(pageIndex: r.pageIndex, x: r.x + r.width / 2, y: r.y + r.height / 2) {
                offset = Double(estimate)
            }
            let key = SortKey(page: mention.pageIndex, offset: offset, top: -(rect.map { $0.y + $0.height } ?? 0), left: rect?.x ?? 0, index: index)
            return (key, mention)
        }
        return keyed.sorted { $0.key < $1.key }.map(\.mention)
    }

    private struct SortKey: Comparable {
        var page: Int
        var offset: Double
        var top: Double
        var left: Double
        var index: Int

        static func < (a: SortKey, b: SortKey) -> Bool {
            (a.page, a.offset, a.top, a.left, a.index) < (b.page, b.offset, b.top, b.left, b.index)
        }
    }
}
