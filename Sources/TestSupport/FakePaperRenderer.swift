import Foundation
import RefereeCore

/// The simplest rendering, stable for ever (ReviewEngine's tests depend on it, not on PaperText's real renderer): for each page in
/// range the line "[[page N]]" (1-based), then the text of each .body line on a line of its own; a final newline.
/// chunkPageRanges adds consecutive pages to a range while its rendering stays within maxCharacters (a single page may exceed it).
///
/// Details that will not change either: `pages` is a range of positions in `paper.pages` (nil = all of them, and a
/// range reaching beyond the paper is cut to it); N is the page's own `index` plus one; every line, the last one
/// included, ends with one "\n", so no pages give the empty string; sizes are counted in Swift characters.
public struct FakePaperRenderer: PaperRendering {
    public init() {}

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
