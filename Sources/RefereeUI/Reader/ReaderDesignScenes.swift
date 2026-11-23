import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The Reader's scenes of the design review (docs/design-review.md, steps 4 and 5): states of the PDF pane that the
// scenes of plan.md section 10.1 do not show. They are the verification scenes of the Reader's changes of step 5.
//
// - design-citation-states (D15): the citation card when a lookup failed, when nothing was found, and for a citation
//   that matches no entry of the reference list. The snapshot graph's resolver resolves every entry, so the model
//   cannot reach the first two states here, and the overlay shows one card at a time; the scene draws the Reader's own
//   card view (`ReaderCitationCard`) for each state, over the PDF column. Each card's content is made as the overlay
//   makes it, by `ReaderCardContent.make` from a `CitationLookup` and the paper's citation index: the lookups the
//   model would hold for real entries of `ay_links.pdf`, and a numbered mention that matches no entry, added to a copy
//   of the index. Remove this workaround once the snapshot graph can fail a lookup.
// - design-find-no-matches: the find bar with a query that is not in the paper.
// - design-selection-asked (D14): a passage selected in the PDF, then a question about it: the conversation is in the
//   Chat tab and the selection bar has stepped aside, while the PDF still marks the passage.
// - design-selection-copied (D14): Copy in the selection bar reads "Copied" (the picture); a moment later the bar steps
//   aside until the selection changes (`verify`). The text goes to a pasteboard of the scene's own.
// - design-references-filter (D23): the References tab with a filter typed: the count "4 of 9 references" and the
//   rows that contain the word.
// - design-find-with-comments (D29): find on a paper with comments: the comment highlights at 40% of their alpha under
//   find's matches; `verify` closes the bar and sees them return.

@MainActor enum ReaderDesignScenes {
    static var all: [SnapshotScene] {
        [citationStates, findNoMatches, selectionAsked, selectionCopied, referencesFilter, findWithComments]
    }

    /// The identifier of the view that holds the three cards, so that `verify` can find it.
    static let cardStackIdentifier = NSUserInterfaceItemIdentifier("design-citation-states")
    /// The date of the scene's invented lookups: fixed, so that nothing in the picture changes between runs.
    static let lookupDate = Date(timeIntervalSince1970: 1_795_000_000)
    /// `ay_nolinks.pdf`, page 1: the abstract's last sentence, on one line of the page.
    static let passage = "The effect is statistically significant but economically small."
    static let question = "Is an effect this small worth the paper's emphasis?"
    /// The word the References scene filters by: in four of the nine entries of `ay_links.pdf`.
    static let referencesFilterWord = "learning"
    /// The pasteboard Copy writes to in `design-selection-copied`: not the general one, which is the referee's.
    static let scenePasteboardName = NSPasteboard.Name("local.referee.snapshot.design-selection-copied")

    // ---- design-citation-states (D15) ----

    static var citationStates: SnapshotScene {
        SnapshotScene(name: "design-citation-states", kind: .review, fixturePDF: "ay_links.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader else { return }
            await ReaderSceneSupport.wait { (model.citations?.entries.count ?? 0) >= 2 }
            guard let (failing, missing) = chosenEntries(model.citations?.entries ?? []),
                  let failed = card(for: failing, status: .failed, citations: model.citations),
                  let notFound = card(for: missing, status: .notFound, citations: model.citations),
                  let unmatched = unmatchedMention(in: model.citations) else { return }
            // On a blank of the page's own white (in both appearances, as a PDF page is), so that no line of the page
            // shows between the cards: they look as the overlay looks over an empty part of a page.
            let cards = VStack(alignment: .leading, spacing: 14) {
                ReaderCitationCard(controller: reader, content: failed)
                ReaderCitationCard(controller: reader, content: notFound)
                ReaderCitationCard(controller: reader, content: unmatched)
            }
            .padding(14)
            .background(Color.white)
            .environment(\.uiActions, UIActions())
            let host = NSHostingView(rootView: cards)
            host.identifier = cardStackIdentifier
            let size = host.fittingSize
            // On the PDF view itself, an AppKit view whose subviews draw as usual (a view added to the window's
            // SwiftUI root is never drawn): centred, 64 points below its top edge, under the toolbar. PDFView is not
            // flipped, so y counts from the bottom.
            let pdfView = reader.pdfView
            let x = max(0, (pdfView.bounds.width - size.width) / 2)
            let y = max(0, pdfView.bounds.height - 64 - size.height)
            host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            pdfView.addSubview(host)
        }, verify: { context in
            guard let model = context.model, let reader = context.reader else { return ["a review scene without a model"] }
            var failures: [String] = []
            guard let (failing, missing) = chosenEntries(model.citations?.entries ?? []) else {
                return ["ay_links.pdf has fewer than two reference entries"]
            }
            if let host = reader.pdfView.subviews.first(where: { $0.identifier == cardStackIdentifier }) {
                if host.layer?.superlayer == nil { failures.append("the three cards are not drawn") }
            } else {
                failures.append("the three cards are not in the PDF view")
            }
            // D15: a failed or not-found card offers Search Google Scholar, prominent, and Show in References, and none
            // of the buttons that cannot act (Retry is part of the failed card's record); the card without an entry
            // offers the search alone.
            let searchOnly = ReaderCardActions(shown: [.searchScholar, .showInReferences], prominent: .searchScholar)
            for (entry, status) in [(failing, ResolutionStatus.failed), (missing, .notFound)] {
                guard let content = card(for: entry, status: status, citations: model.citations),
                      let shownEntry = content.entries.first, let lookup = content.references[shownEntry.id] else {
                    failures.append("the \(status) card has no content")
                    continue
                }
                if lookup.status != status { failures.append("the \(status) card shows a lookup that is \(lookup.status)") }
                let actions = ReaderCardActions.make(reference: lookup, entry: shownEntry)
                if actions != searchOnly { failures.append("the \(status) card offers \(actions.shown), \(actions.prominent) prominent") }
            }
            if let unmatched = unmatchedMention(in: model.citations) {
                if !unmatched.entries.isEmpty { failures.append("the unmatched mention has \(unmatched.entries.count) entries") }
                if unmatched.heading != "[14]" { failures.append("the unmatched mention is headed \"\(unmatched.heading)\", expected \"[14]\"") }
            } else {
                failures.append("the unmatched mention has no card")
            }
            if ReaderCardActions.noEntry.shown != [.searchScholar] { failures.append("the card without an entry offers more than the search") }
            return failures
        })
    }

    /// The entries the cards are about: a working paper (failed lookup) and a book (nothing found), else the first two.
    static func chosenEntries(_ entries: [BibEntry]) -> (failing: BibEntry, missing: BibEntry)? {
        guard entries.count >= 2 else { return nil }
        let failing = entries.first { $0.rawText.localizedCaseInsensitiveContains("working paper") } ?? entries[0]
        let missing = entries.first { $0.rawText.contains("Press") && $0.id != failing.id } ?? entries[1]
        return (failing, missing)
    }

    /// The lookup of `entry` with `status` (failed or not found), as the resolver would answer it.
    static func reference(for entry: BibEntry, status: ResolutionStatus) -> ResolvedReference {
        ResolvedReference(entryID: entry.id, status: status,
                          failureReason: status == .failed ? "Crossref is busy; try again in a minute." : nil,
                          confidence: 0, resolvedAt: lookupDate)
    }

    /// What the card shows for `entry` after a lookup with `status`: the content the overlay makes when the model holds
    /// that lookup for the entry chosen in the References list.
    static func card(for entry: BibEntry, status: ResolutionStatus, citations: CitationIndex?) -> ReaderCardContent? {
        ReaderCardContent.make(.resolved(target: .entry(entry.id), entries: [entry], references: [reference(for: entry, status: status)]),
                               citations: citations)
    }

    /// A numbered citation, "[14", that no entry of the reference list matches, in a copy of the paper's index: the card
    /// the overlay makes for it shows its text and Search Google Scholar only.
    static func unmatchedMention(in citations: CitationIndex?) -> ReaderCardContent? {
        guard var index = citations else { return nil }
        let id = (index.mentions.map(\.id).max() ?? 0) + 1
        index.mentions.append(CitationMention(id: id, pageIndex: 0, text: "[14", source: .textPattern))
        return ReaderCardContent.make(.resolved(target: .mention(id), entries: [], references: []), citations: index)
    }

    // ---- design-find-no-matches ----

    /// The find bar with a word the paper does not contain: "No matches", the arrows disabled.
    static var findNoMatches: SnapshotScene {
        SnapshotScene(name: "design-find-no-matches", kind: .review, fixturePDF: "ay_round_nolinks.pdf", prepare: { context in
            context.reader?.find("heteroskedasticity")
        }, verify: { context in
            guard let finder = context.reader?.finder else { return ["no reader"] }
            var failures: [String] = []
            if !finder.isVisible { failures.append("the find bar is hidden") }
            if finder.resultCount != 0 { failures.append("\(finder.resultCount) matches, expected none") }
            if finder.countText != "No matches" { failures.append("the count reads \"\(finder.countText)\"") }
            return failures
        })
    }

    // ---- design-selection-asked (D14) ----

    /// A passage selected in the PDF as a drag selects it, the bar up, then a question about the passage: the bar steps
    /// aside, the passage stays selected, its conversation is in the Chat tab.
    static var selectionAsked: SnapshotScene {
        let box = ReaderSceneFindings()
        return SnapshotScene(name: "design-selection-asked", kind: .review, fixturePDF: "ay_nolinks.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader else { return }
            guard await ReaderSceneSupport.select(passage, onPage: 0, reader: reader, model: model) else {
                box.failures.append("the passage could not be selected")
                return
            }
            await ReaderSceneSupport.wait { reader.selectionBarSelection != nil }
            if reader.selectionBarSelection == nil { box.failures.append("the selection bar did not appear before the question") }
            model.ask(question, about: model.selection, in: nil)
            await ReaderSceneSupport.wait(seconds: 5) {
                model.streamingTargetID == nil && model.session?.conversations.first?.messages.count == 2
            }
        }, verify: { context in
            guard let model = context.model, let reader = context.reader else { return ["no review model"] }
            var failures = box.failures
            guard let selection = model.selection else { return failures + ["the passage is no longer the model's selection"] }
            if reader.pdfView.currentSelection == nil { failures.append("the PDF no longer marks the passage") }
            if model.session?.conversations.contains(where: { $0.anchor?.spans == selection.spans }) != true {
                failures.append("no conversation is about the selected passage")
            }
            if reader.selectionBar.settled?.spans != selection.spans { failures.append("the selection never settled, so the bar was never due") }
            if reader.selectionBarSelection != nil { failures.append("the selection bar is still shown over the passage") }
            if model.sidebarTab != .chat { failures.append("expected the Chat tab") }
            return failures
        })
    }

    // ---- design-selection-copied (D14) ----

    /// Copy in the selection bar, captured while it reads "Copied"; `verify` then sees the bar step aside. The capture
    /// comes 0.5 s after the copy, well inside the 1.5 s of feedback; pages had 1.5 s to render before it.
    static var selectionCopied: SnapshotScene {
        let box = ReaderSceneFindings()
        return SnapshotScene(name: "design-selection-copied", kind: .review, fixturePDF: "ay_nolinks.pdf", settleSeconds: 0.5, prepare: { context in
            guard let model = context.model, let reader = context.reader else { return }
            guard await ReaderSceneSupport.select(passage, onPage: 0, reader: reader, model: model) else {
                box.failures.append("the passage could not be selected")
                return
            }
            await ReaderSceneSupport.wait { reader.selectionBarSelection != nil }
            guard let selection = reader.selectionBarSelection else {
                box.failures.append("the selection bar did not appear")
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            reader.copySelection(selection, to: NSPasteboard(name: scenePasteboardName))
            box.copied = selection
            if !reader.selectionBar.isShowingCopied(for: selection) { box.failures.append("Copy does not read \"Copied\"") }
        }, verify: { context in
            guard let reader = context.reader else { return ["no reader"] }
            var failures = box.failures
            let pasteboard = NSPasteboard(name: scenePasteboardName)
            defer { pasteboard.releaseGlobally() }
            guard let copied = box.copied else { return failures }
            if pasteboard.string(forType: .string) != copied.text { failures.append("the pasteboard does not hold the passage") }
            await ReaderSceneSupport.wait { reader.selectionBarSelection == nil }
            if reader.selectionBarSelection != nil { failures.append("the bar did not step aside after \"Copied\"") }
            if reader.selectionBar.isShowingCopied(for: copied) { failures.append("\"Copied\" did not go") }
            if context.model?.selection?.spans != copied.spans { failures.append("the passage is no longer selected") }
            return failures
        })
    }

    // ---- design-references-filter (D23) ----

    /// `ay_links.pdf`, navigator on References, "learning" typed in the filter: four of the nine entries.
    static var referencesFilter: SnapshotScene {
        SnapshotScene(name: "design-references-filter", kind: .review, fixturePDF: "ay_links.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader else { return }
            await ReaderSceneSupport.wait { (model.citations?.entries.count ?? 0) > 0 }
            reader.navigator.tab = .references
            reader.navigator.referenceFilter = referencesFilterWord
        }, verify: { context in
            guard let model = context.model, let reader = context.reader else { return ["no review model"] }
            var failures: [String] = []
            if reader.navigator.tab != .references { failures.append("the navigator is not on References") }
            let entries = model.citations?.entries ?? []
            let filter = reader.navigator.referenceFilter
            let shown = entries.filter { ReaderCitationText.entry($0, matches: filter) }
            let count = ReaderCitationText.referenceCount(shown: shown.count, total: entries.count, isFiltering: ReaderCitationText.isFiltering(filter))
            if count != "4 of 9 references" { failures.append("the count reads \"\(count)\", expected \"4 of 9 references\"") }
            let headings = shown.map(ReaderCitationText.entryHeading)
            let expected = ["Acemoglu et al. (2011)", "Kogan (2020)", "Lee (2021)", "Smith and Sørensen (2000)"]
            if headings != expected { failures.append("the rows are \(headings), expected \(expected)") }
            if !model.references.isEmpty { failures.append("filtering looked \(model.references.count) entries up; it must send nothing") }
            return failures
        })
    }

    // ---- design-find-with-comments (D29) ----

    /// `ay_nolinks.pdf` with the sample session, "Table 2" found: its first match lies in the pending comment's passage.
    static var findWithComments: SnapshotScene {
        SnapshotScene(name: "design-find-with-comments", kind: .review, fixturePDF: "ay_nolinks.pdf", fixtureSession: "sample.json", prepare: { context in
            guard let reader = context.reader else { return }
            await ReaderSceneSupport.wait { !reader.highlights.shown.isEmpty }
            reader.find("Table 2")
        }, verify: { context in
            guard let reader = context.reader, let page = reader.pdfView.document?.page(at: 0) else { return ["the display document is not loaded"] }
            var failures: [String] = []
            if !reader.finder.isVisible { failures.append("the find bar is hidden") }
            if reader.finder.resultCount == 0 { failures.append("\"Table 2\" has no match") }
            let shown = reader.highlights.shown
            if shown.isEmpty { failures.append("page 1 shows no highlight") }
            if shown.contains(where: { !$0.isDimmed }) { failures.append("a highlight is not dimmed while the find bar is shown") }
            let dimmedAlphas = ReaderSceneSupport.fillAlphas(on: page)
            if let strongest = dimmedAlphas.max(), strongest > 0.15 { failures.append("a fill has alpha \(strongest) while the find bar is shown") }
            // Closing the bar brings them back.
            reader.finder.close()
            await ReaderSceneSupport.wait { !reader.highlights.shown.isEmpty && !reader.highlights.shown.contains(where: \.isDimmed) }
            if reader.highlights.shown.contains(where: \.isDimmed) { failures.append("the highlights stay dimmed after the find bar closed") }
            if (ReaderSceneSupport.fillAlphas(on: page).max() ?? 0) < 0.3 { failures.append("the fills did not return to their alpha") }
            return failures
        })
    }
}

/// What the steps of a scene found, shared by its `prepare` and its `verify`.
@MainActor final class ReaderSceneFindings {
    var failures: [String] = []
    var copied: SelectionInfo?
}
