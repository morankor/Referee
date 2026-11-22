import AppKit
import RefereeCore

/// Word and PDF files from the report's attributed string (plan.md section 6.10).
@MainActor
enum ExportPrinter {
    static let margin: CGFloat = 72
    /// The title a PDF viewer shows; neutral, because a referee report must not name its author.
    static let documentTitle = "Referee report"

    /// Office Open XML, with the page size and margins of the PDF.
    static func docx(_ text: NSAttributedString, paper: PaperSize) throws -> Data {
        let attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
            .paperSize: NSValue(size: paper.points),
            .leftMargin: margin, .rightMargin: margin, .topMargin: margin, .bottomMargin: margin,
        ]
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        } catch {
            throw ExportError.couldNotCreate("the Word document could not be created: \(error.localizedDescription)")
        }
    }

    /// Prints the text into a PDF of `paper`'s size with 72-point margins, text on every page. The printing system
    /// writes the PDF to a file in `scratch`, which is read and deleted at once.
    ///
    /// The view is laid out in full before it is printed: a plain `NSTextView(frame:)` lays out only what a window
    /// would show, and its PDF has the right number of pages with text on the first one only (section 6.10).
    static func pdf(_ text: NSAttributedString, paper: PaperSize,
                    scratch: URL = FileManager.default.temporaryDirectory) throws -> Data {
        // 1. The text system by hand, in TextKit 1, with a container as wide as the page between its margins and
        //    unlimited in height; full layout; then the view exactly as tall as the text.
        let size = paper.points
        let width = size.width - 2 * margin
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1), textContainer: container)
        view.isEditable = false
        view.isSelectable = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.drawsBackground = false
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        view.setFrameSize(NSSize(width: width, height: max(height, 1)))

        // 2. The page: paper size, 72-point margins, scaled to the width, cut into pages down the height, not
        //    centred, saved to a temporary file.
        let file = scratch.appendingPathComponent("referee-export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let info = NSPrintInfo()
        info.paperSize = size
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file

        // 3. Print without panels, on the main thread; read the file and delete it.
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = documentTitle
        guard operation.run() else { throw ExportError.couldNotCreate("the PDF could not be created") }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ExportError.couldNotCreate("the PDF could not be read back: \(error.localizedDescription)")
        }
        guard data.starts(with: Data("%PDF-".utf8)) else { throw ExportError.couldNotCreate("the printing system did not write a PDF") }
        return data
    }
}

extension PaperSize {
    /// The sheet in points: Letter 612 × 792, A4 595 × 842 (plan section 6.10).
    var points: NSSize {
        switch self {
        case .letter: return NSSize(width: 612, height: 792)
        case .a4: return NSSize(width: 595, height: 842)
        }
    }
}
