import SwiftUI
import AppKit

/// A range of the report to select and show (a lint finding the referee clicked). `serial` changes with every
/// request, so clicking the same finding twice selects it twice.
struct SidebarEditorReveal: Equatable {
    var serial: Int
    var range: NSRange
}

/// The report's plain-text Markdown editor (plan.md section 9.8): a 13-point system font with comfortable line
/// spacing; heading lines are drawn in bold so that the structure shows, but the text stays plain (nothing typed gets
/// an attribute). Read-only while a report or a voice revision streams into it, and then it follows the end of the text.
/// Spelling is checked as the referee types (step 5, D8): the report goes into a web form where a typo stays.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor`, because a lint finding must select its range and scroll to it.
struct SidebarMarkdownEditor: NSViewRepresentable {
    var text: String
    var isEditable: Bool
    var followsEnd = false
    var reveal: SidebarEditorReveal?
    var onEdit: (String) -> Void = { _ in }

    static let fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true          // misspelt words underlined, never corrected (D8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = Self.bodyFont
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.bodyAttributes
        textView.setAccessibilityLabel("Report")
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.string = text
        Self.style(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onEdit = onEdit
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if textView.string != text {
            // The model changed the text (a new draft, a restored version, a stream): take it, and keep the
            // selection where it still fits.
            let selection = textView.selectedRange()
            context.coordinator.isApplyingModelText = true
            textView.string = text
            Self.style(textView)
            context.coordinator.isApplyingModelText = false
            context.coordinator.undoManager.removeAllActions()      // their ranges belong to the text that was replaced
            let length = (text as NSString).length
            if selection.location <= length {
                textView.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, length - selection.location)))
            }
            if followsEnd { textView.scrollToEndOfDocument(nil) }
        }
        if let reveal, reveal.serial != context.coordinator.revealedSerial {
            context.coordinator.revealedSerial = reveal.serial
            let length = (textView.string as NSString).length
            let location = min(max(0, reveal.range.location), length)
            let range = NSRange(location: location, length: min(max(0, reveal.range.length), length - location))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            if range.length > 0 { textView.showFindIndicator(for: range) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (String) -> Void
        var isApplyingModelText = false
        var revealedSerial = 0
        /// The editor's own undo history, so that a text the model replaces takes its history with it.
        let undoManager = UndoManager()

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModelText, let textView = notification.object as? NSTextView else { return }
            SidebarMarkdownEditor.style(textView)
            onEdit(textView.string)
        }
    }

    // ---- look ----

    static var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    static var headingFont: NSFont { .systemFont(ofSize: fontSize, weight: .bold) }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    /// Body attributes everywhere, bold on heading lines ("#" to "######" and a space). Changes no character.
    static func style(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: NSRange(location: 0, length: string.length))
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line, SidebarMarkdown.heading(line.trimmingCharacters(in: .whitespaces)) != nil else { return }
            storage.addAttribute(.font, value: headingFont, range: range)
        }
        storage.endEditing()
        textView.typingAttributes = bodyAttributes
    }
}
