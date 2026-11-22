import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP8a implements the export of section 6.10.

@MainActor public enum ReportExporter {
    /// Placeholder: the Markdown comes back unchanged.
    public static func plainText(fromMarkdown markdown: String) -> String { markdown }

    /// .markdown and .plainText -> UTF-8; .docx; .pdf (paginated, text on every page; section 6.10). Main actor because of AppKit text layout and printing.
    /// Placeholder: .markdown and .plainText give the text as UTF-8; .docx and .pdf throw.
    public static func data(markdown: String, format: ExportFormat, paper: PaperSize = .current) throws -> Data {
        switch format {
        case .markdown: return Data(markdown.utf8)
        case .plainText: return Data(plainText(fromMarkdown: markdown).utf8)
        case .docx, .pdf: throw StoreError.io("Word and PDF export are not implemented yet")
        }
    }
}
