import AppKit
import Foundation
import RefereeCore
import AppCore

/// What the sidebar's snapshot scenes need besides the model's public API (plan.md section 10.1).
@MainActor enum SidebarSceneSupport {
    /// Lets the main actor run until `condition` holds or `seconds` have passed. A scene whose condition never holds
    /// goes on regardless; its `verify` then says what is missing.
    static func wait(seconds: Double = 10, until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The selection the PDF view would report for `passage` on the page with index `pageIndex`, as one span of the
    /// page string; nil when the page does not contain it. The model normalises it like any selection.
    static func selection(of passage: String, onPage pageIndex: Int, in model: ReviewSessionModel) -> SelectionInfo? {
        guard let page = model.paper?.text.pages.first(where: { $0.index == pageIndex }) else { return nil }
        let range = (page.string as NSString).range(of: passage)
        guard range.location != NSNotFound else { return nil }
        return SelectionInfo(text: passage, spans: [TextSpan(pageIndex: pageIndex, range: TextRange(range))])
    }

    /// The card states of the visible comments, as the Comments tab derives them.
    static func cardStates(_ model: ReviewSessionModel) -> [SidebarCardState] {
        let inputs = SidebarCardInputs(model: model)
        return model.visibleComments.map { SidebarCardState.make(for: $0, inputs: inputs) }
    }

    /// A comment id of a session fixture.
    static func id(_ text: String) -> UUID {
        UUID(uuidString: text) ?? UUID()
    }

    /// Switches on a provider of the snapshot registry that `SnapshotSupport.settings()` leaves off (`mock-slow`), with
    /// its model, and makes it this document's provider; waits until the model has its plan (step 5a's notes).
    static func choose(_ id: ProviderID, model name: String, in model: ReviewSessionModel) async {
        var settings = model.settings
        settings.providers[id] = ProviderSettings(enabled: true, model: name, inputMode: .auto)
        model.reloadSettings(settings)
        model.setActiveProvider(ProviderRef(providerID: id, model: name))
        await wait { model.activeProvider?.id == id && model.sendPlan != nil }
    }

    // ---- what the window shows (D2, D8) ----

    /// nil when the keyboard is in a multi-line editor of the comment holding `expectedText` (the editor's Comment
    /// field, D2), else what holds it.
    static func keyboardProblem(in window: NSWindow, expectedText: String) -> String? {
        guard let responder = window.firstResponder else { return "nothing has the keyboard" }
        guard let textView = responder as? NSTextView else { return "the keyboard is in \(type(of: responder)), not in the comment" }
        if textView.isFieldEditor { return "the keyboard is in a one-line field, not in the comment" }
        if textView.string != expectedText { return "the keyboard is in a text holding \"\(textView.string.prefix(40))\", not in the comment" }
        return nil
    }

    /// The report editor's height, the scroll view of the text view whose accessibility label is "Report".
    static func reportEditorHeight(in window: NSWindow) -> CGFloat? {
        guard let root = window.contentView else { return nil }
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let textView = view as? NSTextView, textView.accessibilityLabel() == "Report" {
                return (textView.enclosingScrollView ?? textView).frame.height
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The least height the report editor must have in a window of this height (D8): 470 points at 1,280 × 800 and 320
    /// at 1,000 × 640; nil for another size.
    static func reportEditorMinimum(windowHeight: CGFloat) -> CGFloat? {
        if windowHeight >= 800 { return 470 }
        if windowHeight >= 640 { return 320 }
        return nil
    }

    /// nil when the report editor has the room D8 asks for in this window, else why not.
    static func reportEditorProblem(in window: NSWindow) -> String? {
        guard let height = reportEditorHeight(in: window) else { return "the report editor is not in the window" }
        let windowHeight = window.contentView?.bounds.height ?? 0
        guard let minimum = reportEditorMinimum(windowHeight: windowHeight), height < minimum else { return nil }
        return "the report editor is \(Int(height)) points high in a window of \(Int(windowHeight)), expected at least \(Int(minimum))"
    }
}
