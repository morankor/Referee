import SwiftUI
import AppKit
import PDFKit
import RefereeCore
import AppCore

// The Reader's snapshot scenes (plan.md section 10.1): seven, each with a `verify` where something can be checked
// beyond the picture. They drive the models through their public API, and the reader through what is internal to this
// area (a find query, the navigator's tab), since a scene gets the window, the model and the reader only.
//
// `reader-citation` opens its card the way Wave 3's `check-citation-click` will: the centre of the first rectangle of
// "Acemoglu et al. [2011]" in window coordinates, the view `window.contentView.hitTest` finds there, a mouse-up posted
// with `NSApp.postEvent`, and `mouseDown(with:)` called on the hit view.

@MainActor public enum ReaderScenes {
    public static var all: [SnapshotScene] {
        [highlights, selection, citation, find, references, ruler, referenceViewer] + ReaderDesignScenes.all
    }

    /// Comments of Fixtures/sessions/sample.json (docs/contract-notes/wp0b-testsupport.md, decision 5).
    static let tableCommentID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"      // pending, the Table 2 sentence
    static let rolloutCommentID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"    // approved, fuzzy (0.91)
    static let ownCommentID = "66666666-6666-4666-8666-666666666666"        // the reviewer's own, approved

    /// `ay_nolinks.pdf` with the sample session: two yellow highlights on one passage (drawn once), a green one with the
    /// dashed border of a fuzzy anchor, selected and so stronger, and a blue one, all on page 1; navigator on Pages.
    static var highlights: SnapshotScene {
        SnapshotScene(name: "reader-highlights", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model else { return }
            model.selectedCommentID = model.session?.comments.first { $0.id.uuidString == rolloutCommentID }?.id
        }, verify: { context in
            guard let reader = context.reader, let page = reader.pdfView.document?.page(at: 0) else { return ["the display document is not loaded"] }
            var failures: [String] = []
            let shown = reader.highlights.shown.filter { $0.rect.pageIndex == 0 }
            for style in [Theme.Highlight.pending, .approved, .own] where !shown.contains(where: { $0.style == style }) {
                failures.append("page 1 has no \(style) highlight")
            }
            if !shown.contains(where: { $0.ownerID.uuidString == rolloutCommentID && $0.isSelected && $0.isFuzzy }) {
                failures.append("the selected fuzzy comment is not shown as selected")
            }
            let annotations = page.annotations.filter { ReaderHighlightController.ownerID(of: $0) != nil }
            let fills = annotations.filter { $0.type == "Highlight" }
            if fills.count != shown.count { failures.append("page 1 has \(fills.count) highlight annotations for \(shown.count) highlights") }
            if !annotations.contains(where: { $0.type == "Square" }) { failures.append("the fuzzy anchor has no dashed frame") }
            for annotation in annotations where annotation.bounds.minX < 100 {
                failures.append("a highlight starts at x \(Int(annotation.bounds.minX)), in the margin")
            }
            return failures
        })
    }

    /// `ay_nolinks.pdf`, page 1: the raw selection of section 7.4's example, and the selection bar over its normalised form.
    static var selection: SnapshotScene {
        SnapshotScene(name: "reader-selection", kind: .review, fixturePDF: "ay_nolinks.pdf", prepare: { context in
            guard let reader = context.reader, let model = context.model, let page = reader.pdfView.document?.page(at: 0),
                  let string = page.string else { return }
            let range = (string as NSString).range(of: " As shown by Acemoglu et al. [2011],11\nnetwork structure determines wheth")
            guard range.location != NSNotFound, let raw = page.selection(for: range) else { return }
            reader.pdfView.setCurrentSelection(raw, animate: false)
            await ReaderSceneSupport.wait { model.selection?.rects.count == 2 }
        }, verify: { context in
            guard let selection = context.model?.selection else { return ["model.selection is nil"] }
            var failures: [String] = []
            let expected = "As shown by Acemoglu et al. [2011], network structure determines wheth"
            if selection.text != expected { failures.append("model.selection.text is \"\(selection.text)\", expected \"\(expected)\"") }
            if selection.rects.count != 2 { failures.append("the selection has \(selection.rects.count) rectangles, expected 2") }
            for rect in selection.rects where rect.x < 100 { failures.append("a selection rectangle starts at x \(rect.x)") }
            return failures
        })
    }

    /// `ay_links.pdf`: the card of "Acemoglu et al. [2011]", resolved by the fake resolver, opened by a click that goes the
    /// way of `check-citation-click`.
    static var citation: SnapshotScene {
        SnapshotScene(name: "reader-citation", kind: .review, fixturePDF: "ay_links.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader, let mention = ReaderSceneSupport.acemogluMention(in: model),
                  let rect = mention.rects.first else { return }
            ReaderSceneSupport.click(rect, reader: reader, window: context.window)
            await ReaderSceneSupport.wait {
                if case .resolved = model.citationLookup { return true }
                return false
            }
        }, verify: { context in
            guard let model = context.model, let reader = context.reader else { return ["no review model"] }
            guard let mention = ReaderSceneSupport.acemogluMention(in: model) else { return ["no mention \"Acemoglu et al. [2011\" in the index"] }
            var failures: [String] = []
            switch model.citationLookup {
            case .resolved(let target, _, let references):
                if target != .mention(mention.id) { failures.append("the card is for \(target), expected mention \(mention.id)") }
                if references.first?.status != .resolved { failures.append("the reference is not resolved") }
            case .resolving: failures.append("the lookup is still resolving")
            case .idle: failures.append("the click did not open the card")
            }
            if let page = reader.pdfView.currentPage, reader.pdfView.document?.index(for: page) != 0 {
                failures.append("the click changed the page")
            }
            return failures
        })
    }

    /// `ay_round_nolinks.pdf`: the find bar with "effect", its count and the matches marked.
    static var find: SnapshotScene {
        SnapshotScene(name: "reader-find", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            context.reader?.find("effect")
        }, verify: { context in
            guard let reader = context.reader else { return ["no reader"] }
            var failures: [String] = []
            let finder = reader.finder
            if !finder.isVisible { failures.append("the find bar is hidden") }
            if finder.resultCount < 2 { failures.append("\(finder.resultCount) matches for \"effect\", expected at least 2") }
            if finder.countText != "1 of \(finder.resultCount)" { failures.append("the count reads \"\(finder.countText)\"") }
            if reader.pdfView.highlightedSelections?.count != finder.resultCount { failures.append("the matches are not all marked") }
            return failures
        })
    }

    /// `ay_links.pdf`, navigator on References: three entries looked up (icons), the card of the third at the top of the PDF.
    static var references: SnapshotScene {
        SnapshotScene(name: "reader-references", kind: .review, fixturePDF: "ay_links.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader else { return }
            reader.navigator.tab = .references
            for entry in (model.citations?.entries ?? []).prefix(3) {
                reader.navigator.shownEntryID = entry.id
                model.lookUpEntry(entryID: entry.id)
                await ReaderSceneSupport.wait { model.references[entry.id] != nil }
            }
        }, verify: { context in
            guard let model = context.model, let reader = context.reader else { return ["no review model"] }
            var failures: [String] = []
            if reader.navigator.tab != .references { failures.append("the navigator is not on References") }
            if (model.citations?.entries.count ?? 0) < 9 { failures.append("the reference list has \(model.citations?.entries.count ?? 0) entries, expected 9") }
            if model.references.count != 3 { failures.append("\(model.references.count) entries were looked up, expected 3") }
            if case .resolved(.entry(2), _, _) = model.citationLookup {} else { failures.append("the card of the third entry is not open") }
            return failures
        })
    }

    /// `s1_ruler.pdf` with the sample session: the Table 2 comment selected and revealed, its highlight on the ruler page.
    static var ruler: SnapshotScene {
        SnapshotScene(name: "reader-ruler", kind: .review, fixturePDF: "s1_ruler.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let model = context.model, let comment = model.session?.comments.first(where: { $0.id.uuidString == tableCommentID }) else { return }
            model.selectedCommentID = comment.id
            model.revealSelectedCommentInPDF()
        }, verify: { context in
            guard let comment = context.model?.session?.comments.first(where: { $0.id.uuidString == tableCommentID }) else {
                return ["the Table 2 comment is not in the session"]
            }
            var failures: [String] = []
            if comment.anchor.locationLabel != "p. 1, lines 47–49" {
                failures.append("its label is \"\(comment.anchor.locationLabel)\", expected \"p. 1, lines 47–49\"")
            }
            if comment.anchor.rects.isEmpty { failures.append("the comment has no highlight rectangles") }
            if context.reader?.highlights.shown.contains(where: { $0.ownerID == comment.id && $0.isSelected }) != true {
                failures.append("its highlight is not shown as selected")
            }
            return failures
        })
    }

    /// The reference viewer on `num_twocol_links.pdf`. After the capture, `verify` also presses ⌘+ and ⌘0 in the viewer's
    /// window: its own zoom keys must work there (Wave 3: the main menu no longer takes them while a viewer is key).
    static var referenceViewer: SnapshotScene {
        SnapshotScene(name: "reference-viewer", kind: .referenceViewer, fixturePDF: "num_twocol_links.pdf", verify: { context in
            let views = ReaderSceneSupport.views(of: PDFView.self, in: context.window.contentView).filter { $0.document != nil }
            guard let pdfView = views.first, let document = pdfView.document else { return ["the viewer shows no document"] }
            var failures: [String] = []
            if document.pageCount != 2 { failures.append("the viewer shows \(document.pageCount) pages, expected 2") }
            guard let zoomIn = ReaderSceneSupport.commandKey("+", keyCode: 24), let fitWidth = ReaderSceneSupport.commandKey("0", keyCode: 29) else {
                return failures + ["the key events could not be made"]
            }
            let fitted = pdfView.scaleFactor
            _ = context.window.performKeyEquivalent(with: zoomIn)
            if pdfView.autoScales || pdfView.scaleFactor <= fitted { failures.append("⌘+ in the viewer's window did not zoom in") }
            _ = context.window.performKeyEquivalent(with: fitWidth)
            if !pdfView.autoScales { failures.append("⌘0 in the viewer's window did not fit the width") }
            return failures
        })
    }
}

/// What the scenes share.
@MainActor enum ReaderSceneSupport {
    /// Lets the main actor run until `condition` holds or `seconds` have passed.
    static func wait(seconds: Double = 3, until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The mention "Acemoglu et al. [2011]" of `ay_links.pdf` (its text runs to the end of the year, section 8.4).
    static func acemogluMention(in model: ReviewSessionModel) -> CitationMention? {
        model.citations?.mentions.first { $0.text.hasPrefix("Acemoglu et al.") }
    }

    /// A click at the centre of `rect` as `check-citation-click` makes it (section 10.1): converted to window
    /// coordinates, the view found there by `window.contentView.hitTest`, a mouse-up posted, `mouseDown(with:)` called
    /// on that view. Returns the view that was hit.
    @discardableResult
    static func click(_ rect: PageRect, reader: ReaderController, window: NSWindow) -> NSView? {
        guard let page = reader.pdfView.document?.page(at: rect.pageIndex), let content = window.contentView else { return nil }
        let inView = reader.pdfView.convert(rect.cgRect, from: page)
        let point = reader.pdfView.convert(NSPoint(x: inView.midX, y: inView.midY), to: nil)
        guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return nil }
        let time = ProcessInfo.processInfo.systemUptime
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            NSApp.postEvent(up, atStart: false)
        }
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            hit.mouseDown(with: down)
        }
        return hit
    }

    /// A key-down event of `key` with Command, as the keyboard makes it.
    static func commandKey(_ key: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                         keyCode: keyCode)
    }

    /// Every view of `type` under `root`, depth first.
    static func views<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for subview in root.subviews { found += views(of: type, in: subview) }
        return found
    }
}
