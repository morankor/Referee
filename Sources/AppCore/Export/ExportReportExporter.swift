import Foundation
import RefereeCore

/// The four export formats of the Report tab (plan.md section 6.10). Markdown is the text as it is; plain text, Word
/// and PDF are made from one reading of the Markdown (`ExportMarkdown`), so the three agree on what is a heading, a
/// list item or emphasis.
@MainActor public enum ReportExporter {
    /// For pasting into a journal's web form and for "Copy as plain text": headings on a line of their own followed
    /// by a blank line, emphasis markers removed, numbered lists kept (`ExportPlainText` has the details).
    public static func plainText(fromMarkdown markdown: String) -> String {
        ExportPlainText.render(ExportMarkdown.parse(markdown))
    }

    /// .markdown and .plainText -> UTF-8; .docx; .pdf (paginated, text on every page; section 6.10). Main actor because of AppKit text layout and printing.
    /// Failures throw `ExportError.couldNotCreate`.
    public static func data(markdown: String, format: ExportFormat, paper: PaperSize = .current) throws -> Data {
        switch format {
        case .markdown:
            return Data(markdown.utf8)
        case .plainText:
            return Data(plainText(fromMarkdown: markdown).utf8)
        case .docx:
            return try ExportPrinter.docx(ExportRichText.attributedString(for: ExportMarkdown.parse(markdown)), paper: paper)
        case .pdf:
            return try ExportPrinter.pdf(ExportRichText.attributedString(for: ExportMarkdown.parse(markdown)), paper: paper)
        }
    }
}
