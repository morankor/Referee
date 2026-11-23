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
}
