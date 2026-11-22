import AppKit
import Foundation

/// Reports for the export tests (WP8a, plan.md section 11.4). Invented text only.
enum ExportSamples {
    /// The six headings of the report template (Appendix B.4).
    static let templateHeadings = ["Summary assessment", "Recommendation", "Publication probability", "Major concerns",
                                   "Minor concerns", "Questions for the authors"]

    static let longHeadings = ["Major concerns", "Minor concerns", "Questions for the authors", "Remarks on the appendix"]

    /// "A report of four headings with fourteen long items each" (the PDF row): about 330 characters an item, so that
    /// a page holds roughly nine items and the report runs to six or seven pages.
    static func longReport() -> String {
        var text = ""
        for (section, heading) in longHeadings.enumerated() {
            text += "## \(heading)\n\n"
            for number in 1...14 {
                text += "\(number). Item \(section + 1)-\(number): the estimate in Table \(number) is reported without its standard error, "
                    + "and the text treats a difference of two points as decisive although the interval around it is wide enough to "
                    + "include zero. The authors should report the interval, say how it was computed, and explain why the errors are "
                    + "clustered by market rather than by trader.\n"
            }
            text += "\n"
        }
        return text
    }
}

/// Font traits of an attributed string read back from a file.
@MainActor
enum ExportFontCheck {
    static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold) || NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    static func isItalic(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic) || NSFontManager.shared.traits(of: font).contains(.italicFontMask)
    }

    /// True when every character of the first occurrence of `text` has a font that passes `check`; false when `text`
    /// does not occur.
    static func every(_ text: String, in string: NSAttributedString, _ check: (NSFont?) -> Bool) -> Bool {
        let range = (string.string as NSString).range(of: text)
        guard range.location != NSNotFound, range.length > 0 else { return false }
        var result = true
        string.enumerateAttribute(.font, in: range) { value, _, stop in
            if !check(value as? NSFont) { result = false; stop.pointee = true }
        }
        return result
    }
}
