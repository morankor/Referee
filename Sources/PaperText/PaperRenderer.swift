import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a): the renderer in its simplest form. WP1 replaces it with the
// rules of section 6.2 (joined lines, de-hyphenation, markers at sentence boundaries).

public struct PaperRenderer: PaperRendering {
    public init() {}

    /// Placeholder: one "[[page N]]" marker line per page (1-based), then one text line per `.body` line, each ended
    /// by a line break. `pages` is a range of positions in `paper.pages`; nil means every page.
    public func render(_ paper: PaperText, pages: Range<Int>?) -> String {
        let selected = (pages ?? paper.pages.indices).clamped(to: paper.pages.indices)
        var output = ""
        for page in paper.pages[selected] {
            output += "[[page \(page.index + 1)]]\n"
            for line in page.lines where line.kind == .body {
                output += line.text + "\n"
            }
        }
        return output
    }

    /// Consecutive page ranges, filled greedily; a single page that is larger than the limit gets a range of its own.
    public func chunkPageRanges(_ paper: PaperText, maxCharacters: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var size = 0
        for position in paper.pages.indices {
            let pageSize = render(paper, pages: position..<(position + 1)).count
            if position > start && size + pageSize > maxCharacters {
                ranges.append(start..<position)
                start = position
                size = 0
            }
            size += pageSize
        }
        if start < paper.pages.count { ranges.append(start..<paper.pages.count) }
        return ranges
    }
}
