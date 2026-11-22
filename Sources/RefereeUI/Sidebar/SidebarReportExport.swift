import AppKit
import UniformTypeIdentifiers
import RefereeCore
import AppCore

/// The file items of the Report tab's Export menu (plan.md sections 6.10 and 9.8): an `NSSavePanel`, then
/// `model.exportReport(format:to:)`. Never called by a test or a snapshot scene: the panel would wait for a person.
@MainActor enum SidebarReportExport {
    /// Asks where to save, then writes. Returns the message to show when the export failed; nil when it worked or the
    /// referee cancelled.
    static func run(_ format: ExportFormat, model: ReviewSessionModel) -> String? {
        let panel = NSSavePanel()
        panel.title = "Export Report"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [contentType(of: format)]
        panel.nameFieldStringValue = suggestedFileName(for: format, documentName: model.session?.document.fileName)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try model.exportReport(format: format, to: url)
            return nil
        } catch let error as ExportError {
            return error.userMessage
        } catch {
            return "The report could not be exported."
        }
    }

    static func contentType(of format: ExportFormat) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .plainText: return .plainText
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        case .pdf: return .pdf
        }
    }

    /// "<paper> report.md": the PDF's file name without its extension, then " report" and the format's extension.
    static func suggestedFileName(for format: ExportFormat, documentName: String?) -> String {
        let base = (documentName.map { ($0 as NSString).deletingPathExtension } ?? "").trimmingCharacters(in: .whitespaces)
        let ext: String
        switch format {
        case .markdown: ext = "md"
        case .plainText: ext = "txt"
        case .docx: ext = "docx"
        case .pdf: ext = "pdf"
        }
        return (base.isEmpty ? "Referee report" : base + " report") + "." + ext
    }
}
