import AppKit
import PDFKit
import Observation

// Find in a PDF view (plan.md section 7.6), for the manuscript (through ReaderController) and for the reference
// viewer. `PDFDocument.findString(_:withOptions: [.caseInsensitive])` on the displayed document, at most 5,000 results;
// `pdfView.highlightedSelections` marks them all; `setCurrentSelection(_:animate:)` and `go(to:)` step through them.
//
// Decisions (also in docs/contract-notes/wp9-reader.md):
// - The current match is the PDF view's selection, as section 7.6 says, but it is not a passage the referee chose:
//   ReaderController hands the model no selection while it is current (`owns(_:)`), so no selection bar pops up over
//   each match, and a selection made before the search stops being the model's.
// - Typing searches 0.2 s after the last key; Return goes to the next match, Shift-Return to the previous one; both wrap
//   round. The first match shown is the first on or after the current page.
// - "3 of 17"; "1 of 5000+" when the 5,000 results are cut off; "No matches"; nothing while the field is empty.

@MainActor @Observable
final class ReaderFinder {
    static let maximumResults = 5_000
    static let typingDelay: Duration = .milliseconds(200)

    var isVisible = false
    var query = ""
    private(set) var resultCount = 0
    private(set) var currentIndex: Int?
    private(set) var isCapped = false
    private(set) var hasSearched = false                  // `resultCount` belongs to the query as it was last searched
    private(set) var focusRequest = 0                      // bumped to put the cursor into the find field

    @ObservationIgnored private weak var pdfView: PDFView?
    @ObservationIgnored private var results: [PDFSelection] = []
    @ObservationIgnored private var searchedQuery: String?
    @ObservationIgnored private weak var searchedDocument: PDFDocument?
    @ObservationIgnored private var appliedSelection: PDFSelection?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    /// "3 of 17", "No matches", or "" (section 7.6).
    var countText: String {
        Self.countText(current: currentIndex, count: resultCount, capped: isCapped, searched: hasSearched && !query.isEmpty)
    }

    nonisolated static func countText(current: Int?, count: Int, capped: Bool, searched: Bool) -> String {
        guard searched else { return "" }
        guard count > 0, let current else { return "No matches" }
        return "\(current + 1) of \(count)\(capped ? "+" : "")"
    }

    // ---- what the menu, the bar and the scenes call ----

    /// Edit ▸ Find…: shows the bar and puts the cursor into its field.
    func show() {
        isVisible = true
        focusRequest &+= 1
        if !query.isEmpty, !resultsAreCurrent { search() }
    }

    /// Done, or Esc in the field: hides the bar and the marks of the matches; the query stays for next time.
    func close() {
        isVisible = false
        pendingSearch?.cancel()
        pendingSearch = nil
        clearResults()
    }

    /// The field changed: searches once typing pauses.
    func queryDidChange() {
        pendingSearch?.cancel()
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: Self.typingDelay)
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    /// Searches the displayed document for `query` now and shows the first match on or after the current page.
    func search() {
        pendingSearch?.cancel()
        pendingSearch = nil
        guard let pdfView, let document = pdfView.document, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearResults()
            hasSearched = !query.isEmpty
            return
        }
        var found = document.findString(query, withOptions: [.caseInsensitive])
        isCapped = found.count > Self.maximumResults
        if isCapped { found = Array(found.prefix(Self.maximumResults)) }
        for match in found { match.color = NSColor.findHighlightColor }
        results = found
        resultCount = found.count
        searchedQuery = query
        searchedDocument = document
        hasSearched = true
        pdfView.highlightedSelections = found.isEmpty ? nil : found
        guard !found.isEmpty else {
            currentIndex = nil
            releaseSelection()
            return
        }
        currentIndex = firstIndex(atOrAfter: pdfView.currentPage.map { document.index(for: $0) } ?? 0, in: document)
        showCurrent(animate: false)
    }

    /// Edit ▸ Find Next, Return in the field: the next match, wrapping round.
    func next() { step(by: 1) }

    /// Edit ▸ Find Previous, Shift-Return in the field.
    func previous() { step(by: -1) }

    /// True when `selection` is the current match, which the finder made the PDF view's selection.
    func owns(_ selection: PDFSelection) -> Bool {
        guard let applied = appliedSelection else { return false }
        if applied === selection { return true }
        guard applied.string == selection.string, applied.pages == selection.pages, let page = applied.pages.first else { return false }
        return applied.range(at: 0, on: page) == selection.range(at: 0, on: page)
    }

    /// A new document in the view: the old results mean nothing there.
    func documentDidChange() {
        pendingSearch?.cancel()
        results = []
        resultCount = 0
        currentIndex = nil
        isCapped = false
        hasSearched = false
        searchedQuery = nil
        searchedDocument = nil
        appliedSelection = nil
        if isVisible, !query.isEmpty { search() }
    }

    // ---- inside ----

    private var resultsAreCurrent: Bool {
        searchedQuery == query && searchedDocument != nil && searchedDocument === pdfView?.document
    }

    /// The next or previous match. With the bar hidden it shows the bar; without a query it only puts the cursor into the
    /// field; with results of an older query it searches and shows the first match.
    private func step(by delta: Int) {
        isVisible = true
        guard !query.isEmpty else {
            focusRequest &+= 1
            return
        }
        guard resultsAreCurrent else {
            search()
            return
        }
        guard !results.isEmpty else { return }
        let count = results.count
        currentIndex = ((currentIndex ?? (delta > 0 ? -1 : 0)) + delta + count) % count
        showCurrent(animate: true)
    }

    private func showCurrent(animate: Bool) {
        guard let pdfView, let index = currentIndex, results.indices.contains(index) else { return }
        let match = results[index]
        appliedSelection = match
        pdfView.setCurrentSelection(match, animate: animate)
        pdfView.go(to: match)
    }

    private func firstIndex(atOrAfter pageIndex: Int, in document: PDFDocument) -> Int {
        results.firstIndex { match in
            guard let page = match.pages.first else { return false }
            return document.index(for: page) >= pageIndex
        } ?? 0
    }

    /// Takes the marks away and, when the current match is still the view's selection, that selection too.
    private func clearResults() {
        if let pdfView {
            pdfView.highlightedSelections = nil
            if let current = pdfView.currentSelection, owns(current) { pdfView.clearSelection() }
        }
        results = []
        resultCount = 0
        currentIndex = nil
        isCapped = false
        hasSearched = false
        searchedQuery = nil
        searchedDocument = nil
        appliedSelection = nil
    }

    private func releaseSelection() {
        if let pdfView, let current = pdfView.currentSelection, owns(current) { pdfView.clearSelection() }
        appliedSelection = nil
    }
}
