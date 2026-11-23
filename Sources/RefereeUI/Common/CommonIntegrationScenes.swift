import SwiftUI
import AppKit
import PDFKit
import RefereeCore
import AppCore

// The three integration scenes of plan.md section 10.1 (Wave 3). They check behaviour, not appearance: that the panes
// are connected in the real review window. Each one runs the steps section 10.1 prints, in `prepare` so that the
// picture shows their result, and `verify` reports what did not hold; the steps' own findings are kept in a box that
// both closures share.
//
// - `check-document-loaded`: the window as the app makes it, on `ay_round_nolinks.pdf`; the reader shows the display
//   document, and it has 4 pages.
// - `check-citation-click`: on `ay_links.pdf`, a click at the centre of the first rectangle of the mention
//   "Acemoglu et al. [2011]", made the way section 10.1 says: window coordinates, the view `window.contentView.hitTest`
//   finds there, the matching mouse-up posted with `NSApp.postEvent(_:atStart:)`, then `mouseDown(with:)` on that view.
//   The card opens for that mention and the page does not change.
// - `check-triage-keys`: on the sample session, key-down events for J, A, J, R and then U, K, each passed through
//   `TriageKeymap.intent` and `TriageKeymap.apply`, with "advance after decision" off.

@MainActor public enum IntegrationScenes {
    public static var all: [SnapshotScene] { [documentLoaded, citationClick, triageKeys] }

    // ---- check-document-loaded ----

    static var documentLoaded: SnapshotScene {
        SnapshotScene(name: "check-document-loaded", kind: .review, fixturePDF: "ay_round_nolinks.pdf", verify: { context in
            guard let reader = context.reader, let model = context.model else { return ["the scene has no review model or reader"] }
            var failures: [String] = []
            if !reader.isDocumentLoaded { failures.append("reader.isDocumentLoaded is false") }
            let pages = reader.pdfView.document?.pageCount ?? 0
            if pages != 4 { failures.append("the display document has \(pages) pages, expected 4") }
            if model.phase != .ready { failures.append("the model's phase is \(model.phase), expected ready") }
            if model.paper?.ref.pageCount != 4 { failures.append("the model's paper has \(model.paper?.ref.pageCount ?? 0) pages, expected 4") }
            return failures
        })
    }

    // ---- check-citation-click ----

    static var citationClick: SnapshotScene {
        let box = IntegrationFindings()
        return SnapshotScene(name: "check-citation-click", kind: .review, fixturePDF: "ay_links.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader else {
                box.failures.append("the scene has no review model or reader")
                return
            }
            guard let mention = acemogluMention(in: model) else {
                box.failures.append("model.citations has no mention \"Acemoglu et al. [2011]\"")
                return
            }
            guard let rect = mention.rects.first, let page = reader.pdfView.document?.page(at: rect.pageIndex),
                  let content = context.window.contentView else {
                box.failures.append("the mention \(mention.id) has no rectangle on a page of the display document")
                return
            }
            box.mentionID = mention.id
            box.pageBefore = reader.pdfView.currentPage.flatMap { reader.pdfView.document?.index(for: $0) }

            // The centre of the rectangle in window coordinates, and the view the window finds there.
            let inView = reader.pdfView.convert(rect.cgRect, from: page)
            let point = reader.pdfView.convert(NSPoint(x: inView.midX, y: inView.midY), to: nil)
            guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else {
                box.failures.append("window.contentView.hitTest found no view at \(point)")
                return
            }
            if !hit.isDescendant(of: reader.pdfView) {
                box.failures.append("the click at \(point) reaches \(type(of: hit)), which is not inside the PDF view")
            }
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                                windowNumber: context.window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time,
                                              windowNumber: context.window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 0) else {
                box.failures.append("the mouse events could not be made")
                return
            }
            NSApp.postEvent(up, atStart: false)
            hit.mouseDown(with: down)
            await waitUntil { model.citationLookup != .idle }
            await waitUntil {
                if case .resolving = model.citationLookup { return false }
                return true
            }
        }, verify: { context in
            guard let model = context.model, let reader = context.reader else { return ["the scene has no review model or reader"] }
            var failures = box.failures
            guard let mentionID = box.mentionID else { return failures }
            switch model.citationLookup {
            case .idle:
                failures.append("model.citationLookup is still .idle: the click did not reach the PDF view")
            case .resolving(let target), .resolved(let target, _, _):
                if target != .mention(mentionID) { failures.append("the lookup's target is \(target), expected .mention(\(mentionID))") }
            }
            let pageAfter = reader.pdfView.currentPage.flatMap { reader.pdfView.document?.index(for: $0) }
            if pageAfter != box.pageBefore {
                failures.append("the click changed the PDF view's page from \(box.pageBefore.map(String.init) ?? "none") to \(pageAfter.map(String.init) ?? "none")")
            }
            return failures
        })
    }

    /// The mention "Acemoglu et al. [2011]" (a mention's text runs to the end of its year, section 8.4).
    private static func acemogluMention(in model: ReviewSessionModel) -> CitationMention? {
        model.citations?.mentions.first { mention in
            let text = mention.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.hasPrefix("Acemoglu et al.") && text.contains("2011")
        }
    }

    // ---- check-triage-keys ----

    static var triageKeys: SnapshotScene {
        let box = IntegrationFindings()
        return SnapshotScene(name: "check-triage-keys", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else {
                box.failures.append("the scene has no review model")
                return
            }
            let visible = model.visibleComments
            guard visible.count >= 2 else {
                box.failures.append("the sample session shows \(visible.count) comments, expected at least 2")
                return
            }
            let first = visible[0].id
            let second = visible[1].id
            box.commentIDs = [first, second]
            model.setStatus(.pending, for: first)
            model.setStatus(.pending, for: second)
            var settings = model.settings
            settings.ui.autoAdvanceAfterTriage = false
            model.reloadSettings(settings)
            model.selectedCommentID = nil

            for key in triageKeySequence(["j", "a", "j", "r"], window: context.window) { press(key, on: model, box: box) }
            if status(of: first, in: model) != .approved { box.failures.append("after J, A, J, R the first comment is \(describe(status(of: first, in: model))), expected approved") }
            if status(of: second, in: model) != .rejected { box.failures.append("after J, A, J, R the second comment is \(describe(status(of: second, in: model))), expected rejected") }
            if model.selectedCommentID != second { box.failures.append("after J, A, J, R the second comment is not the selected one") }

            for key in triageKeySequence(["u", "k"], window: context.window) { press(key, on: model, box: box) }
            if status(of: second, in: model) != .pending { box.failures.append("after U, K the second comment is \(describe(status(of: second, in: model))), expected pending") }
            if model.selectedCommentID != first { box.failures.append("after U, K the first comment is not the selected one") }
        }, verify: { context in
            guard let model = context.model else { return ["the scene has no review model"] }
            var failures = box.failures
            guard box.commentIDs.count == 2 else { return failures }
            // The state the picture shows: the first comment approved and selected, the second pending again.
            if status(of: box.commentIDs[0], in: model) != .approved { failures.append("at the end the first comment is not approved") }
            if status(of: box.commentIDs[1], in: model) != .pending { failures.append("at the end the second comment is not pending") }
            if model.selectedCommentID != box.commentIDs[0] { failures.append("at the end the first comment is not selected") }
            return failures
        })
    }

    /// Key-down events as the keyboard makes them, with their US key codes (kVK_ANSI_J and the others).
    private static func triageKeySequence(_ letters: [String], window: NSWindow) -> [NSEvent] {
        let codes: [String: UInt16] = ["j": 38, "k": 40, "a": 0, "r": 15, "u": 32]
        return letters.compactMap { letter in
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: letter, charactersIgnoringModifiers: letter,
                             isARepeat: false, keyCode: codes[letter] ?? 0)
        }
    }

    /// One key: its intent from `TriageKeymap.intent`, applied with `TriageKeymap.apply`.
    private static func press(_ event: NSEvent, on model: ReviewSessionModel, box: IntegrationFindings) {
        guard let intent = TriageKeymap.intent(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                               modifiers: event.modifierFlags) else {
            box.failures.append("the key \"\(event.charactersIgnoringModifiers ?? "")\" has no triage intent")
            return
        }
        TriageKeymap.apply(intent, to: model)
    }

    private static func status(of id: UUID, in model: ReviewSessionModel) -> CommentStatus? {
        model.session?.comments.first { $0.id == id }?.status
    }

    private static func describe(_ status: CommentStatus?) -> String {
        status.map { "\($0)" } ?? "gone"
    }

    /// Lets the main actor run until `condition` holds, three seconds at most.
    private static func waitUntil(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

/// What the steps of a scene found, shared by its `prepare` and its `verify`.
@MainActor private final class IntegrationFindings {
    var failures: [String] = []
    var mentionID: Int?
    var pageBefore: Int?
    var commentIDs: [UUID] = []
}
