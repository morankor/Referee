import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The Reader's scenes of the design review (docs/design-review.md, step 4): states of the PDF pane that the scenes of
// plan.md section 10.1 do not show. They stay in the repository as the verification scenes of the changes the review
// proposes (step 5).
//
// - design-citation-states: the citation card when a lookup failed, when nothing was found, and for a citation that
//   matches no entry of the reference list. The snapshot graph's resolver resolves every entry, so the model cannot
//   reach the first two states here; the scene draws the Reader's own card view for each state, over the PDF column,
//   from real entries of `ay_links.pdf`. Remove this workaround once the snapshot graph can fail a lookup.
// - design-find-no-matches: the find bar with a query that is not in the paper.

@MainActor enum ReaderDesignScenes {
    static var all: [SnapshotScene] {
        [citationStates, findNoMatches]
    }

    /// The identifier of the view that holds the three cards, so that `verify` can find it.
    static let cardStackIdentifier = NSUserInterfaceItemIdentifier("design-citation-states")
    /// The date of the scene's invented lookups: fixed, so that nothing in the picture changes between runs.
    static let lookupDate = Date(timeIntervalSince1970: 1_795_000_000)

    static var citationStates: SnapshotScene {
        SnapshotScene(name: "design-citation-states", kind: .review, fixturePDF: "ay_links.pdf", prepare: { context in
            guard let model = context.model, let reader = context.reader else { return }
            await ReaderSceneSupport.wait { (model.citations?.entries.count ?? 0) >= 2 }
            let entries = model.citations?.entries ?? []
            guard entries.count >= 2 else { return }
            let failing = entries.first { $0.rawText.localizedCaseInsensitiveContains("working paper") } ?? entries[0]
            let missing = entries.first { $0.rawText.contains("Press") && $0.id != failing.id } ?? entries[1]
            let cards = VStack(alignment: .leading, spacing: 14) {
                ReaderCitationCard(controller: reader, content: card(for: failing, status: .failed))
                ReaderCitationCard(controller: reader, content: card(for: missing, status: .notFound))
                ReaderCitationCard(controller: reader, content: unmatchedMention)
            }
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
            if (model.citations?.entries.count ?? 0) < 2 { failures.append("ay_links.pdf has fewer than two reference entries") }
            if let host = reader.pdfView.subviews.first(where: { $0.identifier == cardStackIdentifier }) {
                if host.layer?.superlayer == nil { failures.append("the three cards are not drawn") }
            } else {
                failures.append("the three cards are not in the PDF view")
            }
            return failures
        })
    }

    /// What the card shows for `entry` after a lookup with `status` (failed or not found), as the model would hand it over.
    static func card(for entry: BibEntry, status: ResolutionStatus) -> ReaderCardContent {
        let reference = ResolvedReference(entryID: entry.id, status: status,
                                          failureReason: status == .failed ? "Crossref is busy; try again in a minute." : nil,
                                          confidence: 0, resolvedAt: lookupDate)
        return ReaderCardContent(target: .entry(entry.id), heading: ReaderCitationText.entryHeading(entry), mentionText: nil,
                                 entries: [entry], references: [entry.id: reference], isResolving: false)
    }

    /// A numbered citation that no entry of the reference list matches: its text and Search Google Scholar only.
    static var unmatchedMention: ReaderCardContent {
        ReaderCardContent(target: .mention(-1), heading: "[14]", mentionText: "[14]", entries: [], references: [:], isResolving: false)
    }

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
}
